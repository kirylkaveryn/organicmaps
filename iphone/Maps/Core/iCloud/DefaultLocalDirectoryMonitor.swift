protocol DirectoryMonitor {
  var isStarted: Bool { get }
  var isPaused: Bool { get }

  func start(completion: VoidResultCompletionHandler?)
  func stop()
  func pause()
  func resume()
}

protocol LocalDirectoryMonitor: DirectoryMonitor {
  var directory: URL { get }
  var delegate: LocalDirectoryMonitorDelegate? { get set }
}

protocol LocalDirectoryMonitorDelegate : AnyObject {
  func didFinishGathering(contents: LocalContents)
  func didUpdate(contents: LocalContents)
  func didReceiveLocalMonitorError(_ error: Error)
}

let kKMLTypeIdentifier = "com.google.earth.kml" // only the .kml is supported
private let kBookmarksDirectoryName = "bookmarks"

final class DefaultLocalDirectoryMonitor: LocalDirectoryMonitor {

  typealias Delegate = LocalDirectoryMonitorDelegate

  fileprivate enum State {
    case stopped
    case started(dirSource: DispatchSourceFileSystemObject)
    case debounce(dirSource: DispatchSourceFileSystemObject, timer: Timer)
  }

  static let `default` = DefaultLocalDirectoryMonitor(directory: FileManager.default.bookmarksDirectoryUrl,
                                               matching: kKMLTypeIdentifier,
                                               requestedResourceKeys: [.nameKey])

  private let typeIdentifier: String
  private let requestedResourceKeys: Set<URLResourceKey>
  private let actualResourceKeys: [URLResourceKey]
  private var source: DispatchSourceFileSystemObject?
  private var state: State = .stopped
  private(set) var contents = LocalContents()

  // MARK: - Public properties
  let directory: URL
  var isStarted: Bool { if case .stopped = state { false } else { true } }
  private(set) var isPaused: Bool = true
  weak var delegate: Delegate?

  init(directory: URL, matching typeIdentifier: String, requestedResourceKeys: Set<URLResourceKey>) {
    self.directory = directory
    self.typeIdentifier = typeIdentifier
    self.requestedResourceKeys = requestedResourceKeys
    self.actualResourceKeys = [URLResourceKey](requestedResourceKeys.union([.typeIdentifierKey]))
  }

  // MARK: - Public methods
  func start(completion: VoidResultCompletionHandler? = nil) {
    guard case .stopped = state else { return }

    if let source {
      resume()
      state = .started(dirSource: source)
      return
    }

    let nowTimer = Timer.scheduledTimer(withTimeInterval: .zero, repeats: false) { [weak self] _ in
      self?.debounceTimerDidFire()
    }
    do {
      let directorySource = try DefaultLocalDirectoryMonitor.source(for: directory)
      directorySource.setEventHandler { [weak self] in
        self?.queueDidFire()
      }
      source = directorySource
      state = .debounce(dirSource: directorySource, timer: nowTimer)
      resume()
      completion?(.success)
    } catch {
      stop()
      completion?(.failure(error))
    }
  }

  func stop() {
    pause()
    state = .stopped
    contents.removeAll()
  }

  func pause() {
    source?.suspend()
    isPaused = true
  }

  func resume() {
    source?.resume()
    isPaused = false
  }

  // MARK: - Private
  private static func source(for directory: URL) throws -> DispatchSourceFileSystemObject {
    if !FileManager.default.fileExists(atPath: directory.path) {
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      } catch {
        throw error
      }
    }
    let directoryFileDescriptor = open(directory.path, O_EVTONLY)
    guard directoryFileDescriptor >= 0 else {
      let errorCode = errno
      throw NSError(domain: POSIXError.errorDomain, code: Int(errorCode), userInfo: nil)
    }
    let dispatchSource = DispatchSource.makeFileSystemObjectSource(fileDescriptor: directoryFileDescriptor, eventMask: [.write], queue: DispatchQueue.main)
    dispatchSource.setCancelHandler {
      close(directoryFileDescriptor)
    }
    return dispatchSource
  }

  private func queueDidFire() {
    switch state {
    case .started(let directorySource):
      let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
        self?.debounceTimerDidFire()
      }
      state = .debounce(dirSource: directorySource, timer: timer)
    case .debounce(_, let timer):
      timer.fireDate = Date(timeIntervalSinceNow: 0.2)
      // Stay in the `.debounce` state.
    case .stopped:
      // This can happen if the read source fired and enqueued a block on the
      // main queue but, before the main queue got to service that block, someone
      // called `stop()`.  The correct response is to just do nothing.
      break
    }
  }

  private static func contents(of directory: URL, matching typeIdentifier: String, including: [URLResourceKey]) -> Set<URL> {
    guard let rawContents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: including, options: [.skipsHiddenFiles]) else {
      return []
    }
    let filteredContents = rawContents.filter { url in
      guard let type = try? url.resourceValues(forKeys: [.typeIdentifierKey]), let urlType = type.typeIdentifier else {
        return false
      }
      return urlType == typeIdentifier
    }
    return Set(filteredContents)
  }

  private func debounceTimerDidFire() {
    guard case .debounce(let dirSource, let timer) = state else { fatalError() }
    timer.invalidate()
    state = .started(dirSource: dirSource)

    let newContents = DefaultLocalDirectoryMonitor.contents(of: directory, matching: typeIdentifier, including: actualResourceKeys)
    let newContentMetadataItems = LocalContents(newContents.compactMap { url in
      do {
        let metadataItem = try LocalMetadataItem(fileUrl: url)
        return metadataItem
      } catch {
        delegate?.didReceiveLocalMonitorError(error)
        return nil
      }
    })

    // TODO: This hardcoded check is a workaround for the case when the user has no categories at all (first install on the device). In the real there is one file without no bookmarks. But it should be marked as an 'empty' to start fetching the cloud content. Should be handled more accurate way. Also BookmarksManager.shared().sortedUserCategories() may not be initialized during the sync process beginning.
//    let localContentIsEmpty = BookmarksManager.shared().sortedUserCategories().first(where: { BookmarksManager.shared().category(withId: $0.categoryId).bookmarksCount != 0}) == nil
    // When the contentMetadataItems is empty, it means that we are in the initial state.
    if contents.isEmpty {
      delegate?.didFinishGathering(contents: newContentMetadataItems)
    } else {
      delegate?.didUpdate(contents: newContentMetadataItems)
    }
    contents = newContentMetadataItems
  }
}

private extension DefaultLocalDirectoryMonitor.State {
  var isRunning: Bool {
    switch self {
    case .stopped: return false
    case .started: return true
    case .debounce: return true
    }
  }
}

private extension FileManager {
  var bookmarksDirectoryUrl: URL {
    urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent(kBookmarksDirectoryName, isDirectory: true)
  }
}
