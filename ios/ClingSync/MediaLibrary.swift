import Photos

func loadUITestFiles() -> [MediaFile] {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory.appendingPathComponent("ClingSyncUITestMedia", isDirectory: true)
    try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let fixtures: [(name: String, contents: String)] = [
        ("IMG_0001.JPG", "ui test image 1\n"),
        ("IMG_0004.JPG", "ui test image 4\n"),
    ]

    return fixtures.compactMap { fixture in
        let url = directory.appendingPathComponent(fixture.name)
        try? fixture.contents.data(using: .utf8)?.write(to: url)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date ?? .distantPast
        return MediaFile(localFileURL: url, size: size, modificationDate: modificationDate)
    }
}

func isSelectable(_ file: MediaFile) -> Bool {
    switch file.uploadState {
    case .none, .new:
        return true
    default:
        return false
    }
}

func primaryResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    let preferredTypes: [PHAssetResourceType] = [.photo, .video, .fullSizePhoto, .fullSizeVideo, .pairedVideo]
    for type in preferredTypes {
        if let resource = resources.first(where: { $0.type == type }) {
            return resource
        }
    }
    return resources.first
}

func fileSize(for resource: PHAssetResource) -> Int64 {
    if let size = resource.value(forKey: "fileSize") as? Int64 {
        return size
    }
    if let size = resource.value(forKey: "fileSize") as? CLong {
        return Int64(size)
    }
    return 0
}
