import Foundation
import CoreData

class DataService {
    static let shared = DataService()
    let persistentContainer: NSPersistentContainer

    private init() {
        persistentContainer = NSPersistentContainer(name: "CoreDataModels")
        
        // Disable Core Data debug logging in debug builds for performance
        #if DEBUG
        persistentContainer.persistentStoreDescriptions.first?.setOption(false as NSNumber, forKey: "NSPersistentStoreConnectionPoolMaxSize")
        persistentContainer.persistentStoreDescriptions.first?.setOption(false as NSNumber, forKey: "com.apple.CoreData.ConcurrencyDebug")
        #endif
        
        persistentContainer.loadPersistentStores { (storeDescription, error) in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }
        
        // Enable automatic merging to keep view context in sync with background changes
        persistentContainer.viewContext.automaticallyMergesChangesFromParent = true
        persistentContainer.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
    }

    var context: NSManagedObjectContext {
        return persistentContainer.viewContext
    }
    
    private var _backgroundContext: NSManagedObjectContext?
    
    var backgroundContext: NSManagedObjectContext {
        if _backgroundContext == nil {
            _backgroundContext = persistentContainer.newBackgroundContext()
            _backgroundContext?.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        }
        return _backgroundContext!
    }

    func saveContext () {
        let context = persistentContainer.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                let nserror = error as NSError
                fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
            }
        }
    }
}
