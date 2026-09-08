import Foundation

/// M2: track properties PII scrubbing (varsayılan-açık).
///
/// Anahtar-adı tabanlı (e-posta/telefon/ad-soyadı çağrıştıran anahtarlar) +
/// değer-örüntü tabanlı (e-posta/telefon regex) eşleşen değerler gönderilmeden
/// önce kaldırılır; ham değer ağa çıkmaz. Yalnızca Foundation kullanır, böylece
/// AdvenueCore'un Linux taşınabilirliği korunur.
public enum PIIScrub {
  /// Tam-eşleşme yapılan normalize anahtarlar (küçük harf, alfanümerik dışı
  /// karakterler atılmış). Kısa anahtarlar (`ad`, `tel`) bilinçli olarak
  /// listededir: spec'in anahtar-adı sözleşmesi bunu gerektirir.
  private static let blockedKeys: Set<String> = [
    "email", "emailaddress", "emailadres", "eposta", "mail",
    "phone", "phonenumber", "mobile", "mobilenumber", "mobil",
    "telefon", "telefonno", "tel", "telno", "gsm",
    "firstname", "lastname", "ad", "soyad", "adsoyad", "adisoyadi",
    "fullname", "namesurname", "isim", "isimsoyisim",
  ]

  /// Alt-dize eşleşmesi yapılan parçalar: `user_email`, `phone_number` gibi
  /// bileşik anahtarları yakalar.
  private static let blockedSubstrings = [
    "email", "phone", "telefon", "soyad", "adsoyad", "firstname", "lastname",
    "fullname",
  ]

  private static let emailPattern =
    "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}"

  private static func normalizeKey(_ key: String) -> String {
    key.lowercased().filter { $0.isLetter || $0.isNumber }
  }

  static func isSensitiveKey(_ key: String) -> Bool {
    let normalized = normalizeKey(key)
    if blockedKeys.contains(normalized) { return true }
    return blockedSubstrings.contains { normalized.contains($0) }
  }

  private static func matches(_ value: String, pattern: String) -> Bool {
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive])
    else { return false }
    let range = NSRange(value.startIndex..., in: value)
    return regex.firstMatch(in: value, options: [], range: range) != nil
  }

  /// Telefon sezgiseli: çapasız alt-dize araması YOK — o yaklaşım hex hash
  /// (`sourceUrlHash`), tarih (`2026-09-08`) ve sürüm dizgelerindeki rakam
  /// dizilerini telefon sanıp PII olmayan özellikleri siliyordu. Değerin TÜMÜ
  /// telefon karakterlerinden oluşmalı ve rakam sayısı E.164 aralığında
  /// (10–15) olmalı.
  private static func looksLikePhone(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    let allowed = CharacterSet(charactersIn: "+0123456789 \t.-()")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
      return false
    }
    guard let first = trimmed.first, first == "+" || first.isNumber,
      let last = trimmed.last, last.isNumber
    else { return false }
    return (10...15).contains(trimmed.filter { $0.isNumber }.count)
  }

  /// Dize değer PII örüntüsü taşıyorsa true döner.
  public static func isSensitiveValue(_ value: String) -> Bool {
    matches(value, pattern: emailPattern) || looksLikePhone(value)
  }

  private static func scrubValue(_ value: AdvenueValue) -> AdvenueValue? {
    switch value {
    case .string(let s):
      return isSensitiveValue(s) ? nil : value
    case .array(let items):
      return .array(items.compactMap { scrubValue($0) })
    case .object(let dict):
      guard let cleaned = scrub(dict) else { return nil }
      return .object(cleaned)
    case .int, .double, .bool, .null:
      return value
    }
  }

  /// PII taşıyan girdileri kaldırır. Girdi nil ise nil döner.
  public static func scrub(
    _ properties: [String: AdvenueValue]?
  ) -> [String: AdvenueValue]? {
    guard let properties else { return nil }
    var kept: [String: AdvenueValue] = [:]
    kept.reserveCapacity(properties.count)
    for (key, value) in properties {
      if isSensitiveKey(key) { continue }
      if let cleaned = scrubValue(value) {
        kept[key] = cleaned
      }
    }
    return kept
  }
}
