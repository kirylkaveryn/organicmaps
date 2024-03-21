private let kUDCloudIdentityKey = "com.apple.organicmaps.UbiquityIdentityToken"

protocol CloudDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: CloudContents)
  func didUpdate(contents: CloudContents)
}

final class CloudDirectoryMonitor: NSObject {

  private static let sharedContainerIdentifier: String = {
    var identifier = "iCloud.app.organicmaps"
    #if DEBUG
    identifier.append(".debug")
    #endif
    return identifier
  }()

  static let `default` = CloudDirectoryMonitor(cloudContainerIdentifier: CloudDirectoryMonitor.sharedContainerIdentifier)

  private let metadataQuery = NSMetadataQuery()
  private var containerIdentifier: String
  private var ubiquitousDocumentsDirectory: URL?
//  private(set) var contents = CloudContents()

  weak var delegate: CloudDirectoryMonitorDelegate?

  init(cloudContainerIdentifier: String = CloudDirectoryMonitor.sharedContainerIdentifier) {
    self.containerIdentifier = cloudContainerIdentifier
    super.init()

    setupMetadataQuery()
    subscribeToCloudAvailabilityNotifications()
    fetchUbiquityDirectoryUrl()
  }

  // MARK: - Public
  var isStarted: Bool { return metadataQuery.isStarted }

  func start(completion: ((VoidResult) -> Void)? = nil) {
    guard cloudIsAvailable() else {
      completion?(.failure(CloudSynchronizationError.iCloudIsNotAvailable))
      return
    }
    fetchUbiquityDirectoryUrl { [weak self] result in
      guard let self else { return }
      switch result {
      case .success:
        self.startQuery()
        completion?(.success)
      case .failure(let error):
        completion?(.failure(error))
      }
    }
  }

  func stop() {
    stopQuery()
  }

  func resume() {
    metadataQuery.enableUpdates()
  }

  func pause() {
    metadataQuery.disableUpdates()
  }

  func cloudIsAvailable() -> Bool {
    let cloudToken = FileManager.default.ubiquityIdentityToken
    guard let cloudToken else {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.debug, "Cloud is not available. Cloud token is nil.")
      return false
    }
    do {
      let data = try NSKeyedArchiver.archivedData(withRootObject: cloudToken, requiringSecureCoding: true)
      UserDefaults.standard.set(data, forKey: kUDCloudIdentityKey)
      LOG(.debug, "Cloud is available.")
      return true
    } catch {
      UserDefaults.standard.removeObject(forKey: kUDCloudIdentityKey)
      LOG(.error, "Failed to archive cloud token: \(error)")
      return false
    }
  }

  // MARK: - Private
  func fetchUbiquityDirectoryUrl(completion: ((Result<URL, CloudSynchronizationError>) -> Void)? = nil) {
    if let ubiquitousDocumentsDirectory {
      completion?(.success(ubiquitousDocumentsDirectory))
      return
    }
    DispatchQueue.global().async {
      guard let containerUrl = FileManager.default.url(forUbiquityContainerIdentifier: self.containerIdentifier) else {
        LOG(.error, "Failed to retrieve container's URL for:\(self.containerIdentifier)")
        completion?(.failure(.containerNotFound))
        return
      }
      let documentsContainerUrl = containerUrl.appendingPathComponent(kDocumentsDirectoryName)
      self.ubiquitousDocumentsDirectory = documentsContainerUrl
      completion?(.success(documentsContainerUrl))
    }
  }

  private func subscribeToCloudAvailabilityNotifications() {
    NotificationCenter.default.addObserver(self, selector: #selector(cloudAvailabilityChanged(_:)), name: .NSUbiquityIdentityDidChange, object: nil)
  }

  @objc func cloudAvailabilityChanged(_ notification: Notification) {
    LOG(.debug, "Cloud availability changed to : \(cloudIsAvailable())")
    cloudIsAvailable() ? startQuery() : stopQuery()
  }

  // MARK: - MetadataQuery
  private func setupMetadataQuery() {
    metadataQuery.notificationBatchingInterval = 1
    metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
    metadataQuery.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*.\(kFileExtensionKML)")
    metadataQuery.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

    NotificationCenter.default.addObserver(self, selector: #selector(queryDidFinishGathering(_:)), name: NSNotification.Name.NSMetadataQueryDidFinishGathering, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(queryDidUpdate(_:)), name: NSNotification.Name.NSMetadataQueryDidUpdate, object: nil)
  }

  private func startQuery() {
    LOG(.info, "Start quering metadata.")
    stopQuery()
    metadataQuery.start()
  }

  private func stopQuery() {
    LOG(.info, "Stop quering metadata.")
    metadataQuery.stop()
  }

  @objc private  func queryDidFinishGathering(_ notification: Notification) {
    guard cloudIsAvailable(), notification.object as? NSMetadataQuery === metadataQuery else { return }
    LOG(.info, "NSMetadataQuery did finish gathering.")

    metadataQuery.disableUpdates()
    let results = metadataQuery.results.compactMap { $0 as? NSMetadataItem }
    let newContent = CloudContents(results.map { CloudMetadataItem(metadataItem: $0) })
    metadataQuery.enableUpdates()

    delegate?.didFinishGathering(contents: newContent)
  }

  @objc private func queryDidUpdate(_ notification: Notification) {
    guard cloudIsAvailable(), notification.object as? NSMetadataQuery === metadataQuery else { return }
    guard let changes = notification.userInfo else { fatalError("There is no UserInfo dictionary in the NSMetadataQuery notification.") }

    LOG(.info, "NSMetadataQuery did update.")

    metadataQuery.disableUpdates()
    let results = metadataQuery.results.compactMap { $0 as? NSMetadataItem }
    let newContent = CloudContents(results.map { CloudMetadataItem(metadataItem: $0) })
    metadataQuery.enableUpdates()

    delegate?.didUpdate(contents: newContent)
  }
}
