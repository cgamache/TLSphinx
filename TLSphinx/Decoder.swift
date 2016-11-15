//
//  Decoder.swift
//  TLSphinx
//
//  Created by Bruno Berisso on 5/29/15.
//  Copyright (c) 2015 Bruno Berisso. All rights reserved.
//

import Foundation
import AVFoundation
import Sphinx


private enum SpeechStateEnum : CustomStringConvertible {
    case silence
    case speech
    case utterance
    
    var description: String {
        get {
            switch(self) {
            case .silence:
                return "Silence"
            case .speech:
                return "Speech"
            case .utterance:
                return "Utterance"
            }
        }
    }
}

private extension Float {
    func toInt16() -> Int16? {
        if (self > Float(Int16.min) && self < Float(Int16.max) && !self.isNaN) {
            return Int16(self)
        } else {
            return nil
        }
    }
}


private extension AVAudioPCMBuffer {

    func toData() -> Data {
        
        if (int16ChannelData != nil) {
            let channels = UnsafeBufferPointer(start: int16ChannelData, count: 1)
            let ch0Data = Data(bytes: channels[0], count:Int(frameCapacity * format.streamDescription.pointee.mBytesPerFrame))
            return ch0Data
        }
        
        if (floatChannelData != nil) {
            let channels = UnsafeBufferPointer(start: floatChannelData, count: 1)
            let length : Int = Int(frameLength)
            let floatChannelPtr : UnsafeMutablePointer<Float32> = channels[0]
            let intChannelPtr : UnsafeMutablePointer<Int16> = UnsafeMutablePointer<Int16>.allocate(capacity: length)
            for index in 0...length {
                guard let intValue = (floatChannelPtr[index] * 32767).toInt16() else {
                    intChannelPtr[index] = 0
                    continue
                }
                intChannelPtr[index] = intValue
            }
            let ch0Data = Data(bytes: intChannelPtr, count:length)
            intChannelPtr.deallocate(capacity: length)
            return ch0Data
        }
        return Data()
        
    }

}


open class Decoder {
    
    fileprivate var psDecoder: OpaquePointer?
    fileprivate var engine: AVAudioEngine!
    fileprivate var speechState: SpeechStateEnum
    
    open var bufferSize: Int = 2048
    
    public init?(config: Config) {
        
        speechState = .silence
        
        if config.cmdLnConf != nil{
            psDecoder = ps_init(config.cmdLnConf)
            
            if psDecoder == nil {
                return nil
            }
            
        } else {
            psDecoder = nil
            return nil
        }
    }
    
    deinit {
        let refCount = ps_free(psDecoder)
        assert(refCount == 0, "Can't free decoder, it's shared among instances")
    }
    
    @discardableResult fileprivate func process_raw(_ data: Data) -> CInt {
        //Sphinx expect words of 2 bytes but the NSFileHandle read one byte at time so the lenght of the data for sphinx is the half of the real one.
        let dataLength = data.count / 2
        let numberOfFrames = ps_process_raw(psDecoder, (data as NSData).bytes.bindMemory(to: int16.self, capacity: data.count), dataLength, SFalse, SFalse)
        let hasSpeech = in_speech()
        
        switch (speechState) {
        case .silence where hasSpeech:
            speechState = .speech
        case .speech where !hasSpeech:
            speechState = .utterance
        case .utterance where !hasSpeech:
            speechState = .silence
        default:
            break
        }
        
        return numberOfFrames
    }
    
    fileprivate func in_speech() -> Bool {
        return ps_get_in_speech(psDecoder) == 1
    }
    
    @discardableResult fileprivate func start_utt() -> Bool {
        return ps_start_utt(psDecoder) == 0
    }
    
    @discardableResult fileprivate func end_utt() -> Bool {
        return ps_end_utt(psDecoder) == 0
    }
    
    fileprivate func get_hyp() -> Hypothesis? {
        var score: int32 = 0

        if let string = ps_get_hyp(psDecoder, &score) {
            if let text = String(validatingUTF8: string) {
                return Hypothesis(text: text, score: Int(score))
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    fileprivate func hypothesisForSpeechAtPath (_ filePath: String) -> Hypothesis? {
        
        if let fileHandle = FileHandle(forReadingAtPath: filePath) {
            
            start_utt()
            
            let hypothesis = fileHandle.reduceChunks(bufferSize, initial: nil, reducer: { [unowned self] (data: Data, partialHyp: Hypothesis?) -> Hypothesis? in
                
                self.process_raw(data)
                
                var resultantHyp = partialHyp
                if self.speechState == .utterance {
                    
                    self.end_utt()
                    resultantHyp = partialHyp + self.get_hyp()
                    self.start_utt()
                }
                
                return resultantHyp
            })
            
            end_utt()
            fileHandle.closeFile()
            
            //Process any pending speech
            if speechState == .speech {
                return hypothesis + get_hyp()
            } else {
                return hypothesis
            }
            
        } else {
            return nil
        }
    }
    
    open func decodeSpeechAtPath (_ filePath: String, complete: @escaping (Hypothesis?) -> ()) {
        
        DispatchQueue.global().async {
            
            let hypothesis = self.hypothesisForSpeechAtPath(filePath)
            
            DispatchQueue.main.async {
                complete(hypothesis)
            }
        }
    }
    
    open func startDecodingSpeech (_ utteranceComplete: @escaping (Hypothesis?) -> ()) {

        do {
            try AVAudioSession.sharedInstance().setCategory(AVAudioSessionCategoryRecord)
        } catch let error as NSError {
            print("Error setting the shared AVAudioSession: \(error)")
            return
        }

        engine = AVAudioEngine()
        
        guard let input = engine.inputNode else {
            print("Can't get input node")
            return
        }
        
        let mixer = AVAudioMixerNode();
        engine.attach(mixer)
        mixer.volume = 1.0
        engine.connect(input, to: mixer, format: mixer.outputFormat(forBus: 0))
        mixer.installTap(onBus: 0, bufferSize: 4096, format: mixer.outputFormat(forBus: 0), block: { (buffer: AVAudioPCMBuffer!, time: AVAudioTime!) -> Void in
            
            let audioData = buffer.toData()
            self.process_raw(audioData)
            
            if self.speechState == .utterance {
                
                self.end_utt()
                let hypothesis = self.get_hyp()
                
                DispatchQueue.main.async(execute: {
                    utteranceComplete(hypothesis)
                })
                
                self.start_utt()
            }
        })

        
        engine.prepare()

        start_utt()

        do {
            try engine.start()
        } catch let error as NSError {
            end_utt()
            print("Can't start AVAudioEngine: \(error)")
        }
    }

    open func stopDecodingSpeech () {
        engine.stop()
        engine.reset()
        engine = nil
    }
}
