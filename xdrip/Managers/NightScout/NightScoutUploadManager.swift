import Foundation
import os
import UIKit

public class NightScoutUploadManager:NSObject {
    
    // MARK: - properties
    
    /// path for readings and calibrations
    private let nightScoutEntriesPath = "/api/v1/entries"
    
    /// path for treatments
    private let nightScoutTreatmentPath = "/api/v1/treatments"
    
    /// path for devicestatus
    private let nightScoutDeviceStatusPath = "/api/v1/devicestatus"
    
    /// path to test API Secret
    private let nightScoutAuthTestPath = "/api/v1/experiments/test"

    /// for logging
    private var log = OSLog(subsystem: Constants.Log.subSystem, category: Constants.Log.categoryNightScoutUploadManager)
    
    /// BgReadingsAccessor instance
    private let bgReadingsAccessor:BgReadingsAccessor
    
    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper:KeyValueObserverTimeKeeper = KeyValueObserverTimeKeeper()
    
    /// in case errors occur like credential check error, then this closure will be called with title and message
    private let errorMessageHandler:((String, String) -> Void)?
    
    // MARK: - initializer
    
    /// initializer
    /// - parameters:
    ///     - bgReadingsAccessor : needed to get latest readings
    ///     - errorMessageHandler : in case errors occur like credential check error, then this closure will be called with title and message
    init(bgReadingsAccessor:BgReadingsAccessor, errorMessageHandler:((_ title:String, _ message:String) -> Void)?) {
        
        // init properties
        self.bgReadingsAccessor = bgReadingsAccessor
        self.errorMessageHandler = errorMessageHandler
        
        super.init()
        
        // add observers for nightscout settings which may require testing and/or start synchronize
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutAPIKey.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightScoutUrl.rawValue, options: .new, context: nil)
    }
    
    // MARK: - public functions
    
    /// synchronizes all NightScout related, if needed
    public func synchronize() {
        // check if NightScout upload is enabled
        if UserDefaults.standard.nightScoutEnabled && UserDefaults.standard.isMaster, let siteURL = UserDefaults.standard.nightScoutUrl, let apiKey = UserDefaults.standard.nightScoutAPIKey {
            uploadBgReadingsToNightScout(siteURL: siteURL, apiKey: apiKey)
        }
    }
    
    // MARK: - overriden functions
    
    // when one of the observed settings get changed, possible actions to take
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        if let keyPath = keyPath {
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                
                switch keyPathEnum {
                case UserDefaults.Key.nightScoutUrl, UserDefaults.Key.nightScoutAPIKey :
                    // apikey or nightscout api key change is triggered by user, should not be done within 200 ms
                    
                    if (keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {
                        
                        // if apiKey and siteURL are set and if master then test credentials
                        if let apiKey = UserDefaults.standard.nightScoutAPIKey, let siteUrl = UserDefaults.standard.nightScoutUrl, UserDefaults.standard.isMaster {
                            
                            testNightScoutCredentials(apiKey: apiKey, siteURL: siteUrl, { (success, error) in
                                DispatchQueue.main.async {
                                    self.presentNightScoutTestCredentialsResult(success: success, error: error)
                                    if success {
                                        self.synchronize()
                                    } else {
                                        os_log("in observeValue, NightScout credential check failed", log: self.log, type: .info)
                                    }
                                }
                            })
                        }
                    }
                    
                case UserDefaults.Key.nightScoutEnabled :
                    
                    // if changing to enabled, then do a credentials test and if ok start synchronize, if fail don't give warning, that's the only difference with previous cases
                    if (keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 200)) {
                        
                        if UserDefaults.standard.nightScoutEnabled {
                            
                            // if apiKey and siteURL are set and if master then test credentials
                            if let apiKey = UserDefaults.standard.nightScoutAPIKey, let siteUrl = UserDefaults.standard.nightScoutUrl, UserDefaults.standard.isMaster {
                                
                                testNightScoutCredentials(apiKey: apiKey, siteURL: siteUrl, { (success, error) in
                                    DispatchQueue.main.async {
                                        if success {
                                            self.synchronize()
                                        } else {
                                            os_log("in observeValue, NightScout credential check failed", log: self.log, type: .info)
                                        }
                                    }
                                })
                            }
                        }
                    }

                default:
                    break
                }
            }
        }
    }
    
    // MARK: - private helper functions
    
    private func uploadBgReadingsToNightScout(siteURL:String, apiKey:String) {
        
        os_log("in uploadBgReadingsToNightScout", log: self.log, type: .info)

        // get readings to upload, limit to 2016 = maximum 1 week - just to avoid a huge array is being returned here
        let bgReadingsToUpload = bgReadingsAccessor.getLatestBgReadings(limit: 2016, fromDate: UserDefaults.standard.timeStampLatestNightScoutUploadedBgReading, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)
        
        if bgReadingsToUpload.count > 0 {
            os_log("    number of readings to upload : %{public}@", log: self.log, type: .info, bgReadingsToUpload.count.description)

            // map readings to dictionaryRepresentation
            let bgReadingsDictionaryRepresentation = bgReadingsToUpload.map({$0.dictionaryRepresentation})
            
            do {
                // transform to json
                let sendData = try JSONSerialization.data(withJSONObject: bgReadingsDictionaryRepresentation, options: [])
                
                // get shared URLSession
                let sharedSession = URLSession.shared
                
                if let url = URL(string: siteURL) {
                    // create upload url
                    let uploadURL = url.appendingPathComponent(nightScoutEntriesPath)
                    
                    // Create Request
                    var request = URLRequest(url: uploadURL)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    request.setValue(apiKey.sha1(), forHTTPHeaderField: "api-secret")
                    
                    // Create upload Task
                    let dataTask = sharedSession.uploadTask(with: request, from: sendData, completionHandler: { (data, response, error) -> Void in
                        
                        os_log("in uploadTask completionHandler", log: self.log, type: .info)
                        
                        // error cases
                        if let error = error {
                            os_log("    failed to upload, error = %{public}@", log: self.log, type: .error, error.localizedDescription)
                            return
                        }
                        
                        // check that response is HTTPURLResponse and error code between 200 and 299
                        if let response = response as? HTTPURLResponse {
                            guard (200...299).contains(response.statusCode) else {
                                os_log("    failed to upload, statuscode = %{public}@", log: self.log, type: .error, response.statusCode.description)
                                
                                return
                            }
                        } else {
                            os_log("    response is not HTTPURLResponse", log: self.log, type: .error)
                        }
                        
                        // successful cases, change timeStampLatestNightScoutUploadedBgReading
                        if let lastReading = bgReadingsToUpload.first {
                            os_log("    upload succeeded, setting timeStampLatestNightScoutUploadedBgReading to %{public}@", log: self.log, type: .info, lastReading.timeStamp.description(with: .current))
                            UserDefaults.standard.timeStampLatestNightScoutUploadedBgReading = lastReading.timeStamp
                        }
                        
                        // log the result from NightScout
                        guard let data = data, !data.isEmpty else {
                            os_log("    empty response received", log: self.log, type: .info)
                            return
                        }
                        
                    })
                    dataTask.resume()
                }
            } catch let error {
                os_log("     %{public}@", log: self.log, type: .info, error.localizedDescription)
            }
            
        } else {
            os_log("    no readings to upload", log: self.log, type: .info)
        }
        
    }
    
    private func testNightScoutCredentials(apiKey:String, siteURL:String, _ completion: @escaping (_ success: Bool, _ error: Error?) -> Void) {
        
        if let url = URL(string: siteURL) {
            let testURL = url.appendingPathComponent(nightScoutAuthTestPath)
            
            var request = URLRequest(url: testURL)
            request.setValue("application/json", forHTTPHeaderField:"Content-Type")
            request.setValue("application/json", forHTTPHeaderField:"Accept")
            request.setValue(apiKey.sha1(), forHTTPHeaderField:"api-secret")
            
            let task = URLSession.shared.dataTask(with: request, completionHandler: { (data, response, error) in
                if let error = error {
                    completion(false, error)
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse ,
                    httpResponse.statusCode != 200, let data = data {
                    completion(false, NSError(domain: "", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: String.Encoding.utf8)!]))
                } else {
                    completion(true, nil)
                }
            })
            task.resume()
        }
    }
    
    private func presentNightScoutTestCredentialsResult(success:Bool, error:Error?) {
        // define the title text
        var title = Texts_NightScoutTestResult.verificationSuccessFulAlertTitle
        if !success {
            title = Texts_NightScoutTestResult.verificationErrorAlertTitle
        }
        
        // define the message text
        var message = Texts_NightScoutTestResult.verificationSuccessFulAlertBody
        if !success {
            if let error = error {
                message = error.localizedDescription
            } else {
                message = "unknown error"// shouldn't happen
            }
        }

        // call errormessageHandler
        if let errorMessageHandler = errorMessageHandler {
            errorMessageHandler(title, message)
        }
    }
    
}
