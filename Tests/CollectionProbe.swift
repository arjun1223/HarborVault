import AppKit

final class ProbeItem: NSCollectionViewItem {
    override func loadView() { view = NSView() }
}
final class ProbeSource: NSObject, NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { 1 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("Probe"), for: indexPath)
    }
}
@main struct CollectionProbe {
    @MainActor static func main() {
        // No windows, vaults, authentication prompts, or other apps are used.
        for layoutFirst in [false, true] {
            let collection = NSCollectionView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
            let identifier = NSUserInterfaceItemIdentifier("Probe")
            let source = ProbeSource(); collection.dataSource = source
            if layoutFirst { collection.collectionViewLayout = NSCollectionViewFlowLayout() }
            collection.register(ProbeItem.self, forItemWithIdentifier: identifier)
            if !layoutFirst { collection.collectionViewLayout = NSCollectionViewFlowLayout() }
            let exception = HarborCatchException {
                collection.reloadData()
                let item = collection.makeItem(withIdentifier: identifier, for: IndexPath(item: 0, section: 0))
                _ = item.view
            }
            print("layoutFirst=\(layoutFirst): \(exception ?? "OK")")
        }
    }
}
