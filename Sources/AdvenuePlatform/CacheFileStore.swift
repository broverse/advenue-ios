import AdvenueCore
import Foundation

/// B4: dosya destekli anahtar-değer deposu. Caches dizini iCloud/yedek
/// kapsamı dışındadır — kuyruk blob'u (reklam kimlikli olay gövdeleri)
/// yedek imajına sızmaz. Linux taşınabilirliği için yalnızca Foundation.
public struct CacheFileStore: KeyValueStore, @unchecked Sendable {
  private let directory: URL
  private let fileManager = FileManager.default

  /// - Parameter directory: Kök dizin. Üretimde Caches/advenue kullanılır;
  ///   testler geçici dizin verir.
  public init(directory: URL) {
    self.directory = directory
  }

  public static func caches() -> CacheFileStore? {
    guard
      let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let directory = base.appendingPathComponent("advenue", isDirectory: true)
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    return CacheFileStore(directory: directory)
  }

  private func file(forKey key: String) -> URL {
    // Anahtar dosya adı olur — boş/kök kaçışı engellenir.
    let safe = key.replacingOccurrences(of: "/", with: "_")
    return directory.appendingPathComponent(safe, isDirectory: false)
  }

  public func string(forKey key: String) -> String? {
    try? String(contentsOf: file(forKey: key), encoding: .utf8)
  }

  public func set(_ value: String, forKey key: String) {
    try? fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true)
    try? value.write(to: file(forKey: key), atomically: true, encoding: .utf8)
  }

  public func removeObject(forKey key: String) {
    try? fileManager.removeItem(at: file(forKey: key))
  }
}

/// B4: bileşik depo — kuyruk blob'u dosyalara (yedek dışı), geri kalan
/// UserDefaults'a. Android `CompositeStore` ile aynı yönlendirme.
/// Eski UserDefaults anahtarı ilk okumada migrate edilir (RN uyumluluğu).
public struct CompositeStore: KeyValueStore, @unchecked Sendable {
  private let defaults: UserDefaultsStore
  private let files: CacheFileStore
  private let fileKeys: Set<String>

  public init(
    defaults: UserDefaultsStore = UserDefaultsStore(),
    files: CacheFileStore,
    fileKeys: Set<String> = [QUEUE_KEY]
  ) {
    self.defaults = defaults
    self.files = files
    self.fileKeys = fileKeys
  }

  public func string(forKey key: String) -> String? {
    guard fileKeys.contains(key) else { return defaults.string(forKey: key) }
    if let hit = files.string(forKey: key) { return hit }
    // Tek seferlik geriye dönük migrate: RN/önceki sürüm UserDefaults'ta bıraktı.
    guard let legacy = defaults.string(forKey: key) else { return nil }
    files.set(legacy, forKey: key)
    defaults.removeObject(forKey: key)
    return legacy
  }

  public func set(_ value: String, forKey key: String) {
    if fileKeys.contains(key) {
      files.set(value, forKey: key)
    } else {
      defaults.set(value, forKey: key)
    }
  }

  public func removeObject(forKey key: String) {
    if fileKeys.contains(key) {
      files.removeObject(forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}
