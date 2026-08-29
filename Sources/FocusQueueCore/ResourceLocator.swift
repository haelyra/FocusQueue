import Foundation

public enum ResourceLocator {
  public static func url(for rawValue: String) -> URL? {
    if rawValue.hasPrefix("/") {
      return URL(fileURLWithPath: rawValue)
    }

    guard let url = URL(string: rawValue) else { return nil }
    if url.scheme?.lowercased() == "vscode", url.host?.lowercased() == "file" {
      let decodedPath = url.path.removingPercentEncoding ?? url.path
      guard decodedPath.hasPrefix("/") else { return nil }
      return URL(fileURLWithPath: decodedPath)
    }
    return url
  }
}
