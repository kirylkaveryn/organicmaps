protocol MetadataItem: Equatable, Hashable {
  var fileName: String { get }
  var fileUrl: URL { get }
  var fileSize: Int? { get }
  var contentType: String { get }
  var creationDate: Date { get }
  var lastModificationDate: Date { get }
}

struct CloudMetadataItem: MetadataItem {
  let fileName: String
  let fileUrl: URL
  let fileSize: Int?
  let contentType: String
  var isDownloaded: Bool
  var downloadAmount: Double?
  let creationDate: Date
  var lastModificationDate: Date
  var isInTrash: Bool
}

extension CloudMetadataItem {
  // TODO: remove force unwraps
  init(metadataItem: NSMetadataItem) {
    fileName = metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as! String
    fileUrl = metadataItem.value(forAttribute: NSMetadataItemURLKey) as! URL
    fileSize = metadataItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int
    contentType = metadataItem.value(forAttribute: NSMetadataItemContentTypeKey) as! String
    downloadAmount = metadataItem.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double
    let downloadStatus = metadataItem.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
    isDownloaded = downloadStatus == NSMetadataUbiquitousItemDownloadingStatusCurrent
    creationDate = metadataItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as! Date
    lastModificationDate = metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as! Date
    isInTrash = fileUrl.pathComponents.contains(kTrashDirectoryName)
  }
}

struct LocalMetadataItem: MetadataItem {
  let fileName: String
  let fileUrl: URL
  let fileSize: Int?
  let contentType: String
  let creationDate: Date
  let lastModificationDate: Date
}

extension LocalMetadataItem {
  // TODO: remove force unwraps
  init(metadataItem: NSMetadataItem) {
    fileName = metadataItem.value(forAttribute: NSMetadataItemFSNameKey) as! String
    fileUrl = metadataItem.value(forAttribute: NSMetadataItemURLKey) as! URL
    fileSize = metadataItem.value(forAttribute: NSMetadataItemFSSizeKey) as? Int
    contentType = metadataItem.value(forAttribute: NSMetadataItemContentTypeKey) as! String
    creationDate = metadataItem.value(forAttribute: NSMetadataItemFSCreationDateKey) as! Date
    lastModificationDate = metadataItem.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as! Date
  }

  // TODO: remove force unwraps
  init(fileUrl: URL) {
    fileName = fileUrl.lastPathComponent
    self.fileUrl = fileUrl
    fileSize = try? fileUrl.resourceValues(forKeys: [.fileSizeKey]).fileSize
    contentType = try! fileUrl.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier!
    creationDate = try! fileUrl.resourceValues(forKeys: [.creationDateKey]).creationDate!
    lastModificationDate = try! fileUrl.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
  }

  func fileData() throws -> Data {
    try Data(contentsOf: fileUrl)
  }
}
