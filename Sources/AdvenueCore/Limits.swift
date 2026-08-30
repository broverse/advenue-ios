import Foundation

/// `clientEventSchema.name` — min 1, max 128.
public let MAX_NAME_LENGTH = 128
/// `propertiesSchema` — at most this many keys.
public let MAX_PROPERTIES_KEYS = 50
/// `propertiesSchema` — serialised length must not exceed this.
public let MAX_PROPERTIES_BYTES = 8192

/// Reasons `track()` refuses an event. Raw values match the TypeScript
/// implementation so an `onError` context reads the same across SDKs.
public enum TrackRejection: String, Sendable {
  case nameEmpty = "name_empty"
  case nameTooLong = "name_too_long"
  case propertiesTooManyKeys = "properties_too_many_keys"
  case propertiesTooLarge = "properties_too_large"
  case propertiesUnserialisable = "properties_unserialisable"
}

/// Client-side enforcement of the ingest schema's budgets.
///
/// The server parses a batch as a whole, so an event it will reject costs an
/// isolation pass — one failed batch POST followed by up to `batchSize`
/// individual POSTs on a mobile radio — and the event is discarded regardless.
/// Refusing here loses the same one event and spends nothing.
///
/// Values mirror `packages/shared/src/events.ts`, which is the authority.
public func checkTrackInput(
  name: String,
  properties: [String: AdvenueValue]?
) -> TrackRejection? {
  if name.isEmpty { return .nameEmpty }
  if name.count > MAX_NAME_LENGTH { return .nameTooLong }
  guard let properties else { return nil }
  if properties.count > MAX_PROPERTIES_KEYS { return .propertiesTooManyKeys }
  guard let data = try? EventEncoding.canonicalEncoder().encode(properties) else {
    return .propertiesUnserialisable
  }
  if data.count > MAX_PROPERTIES_BYTES { return .propertiesTooLarge }
  return nil
}
