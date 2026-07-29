import Cocoa
import FlutterMacOS
import UserNotifications

class MainFlutterWindow: NSWindow {
  private var securityScopedURLs: [String: URL] = [:]

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    let desktopChannel = FlutterMethodChannel(
      name: "app.meow/desktop",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    desktopChannel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any] else {
        result(
          FlutterError(
            code: "invalid_arguments",
            message: "Desktop service arguments are missing.",
            details: nil
          )
        )
        return
      }

      switch call.method {
      case "notifyCompleted":
        guard
          let identifier = arguments["id"] as? String,
          let outputPath = arguments["outputPath"] as? String
        else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "Notification arguments are invalid.",
              details: nil
            )
          )
          return
        }
        let content = UNMutableNotificationContent()
        content.title = "Translation completed"
        content.body = URL(fileURLWithPath: outputPath).lastPathComponent
        content.sound = .default
        content.userInfo = ["outputPath": outputPath]
        let request = UNNotificationRequest(
          identifier: identifier,
          content: content,
          trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
          DispatchQueue.main.async {
            if let error {
              result(
                FlutterError(
                  code: "notification_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
            } else {
              result(nil)
            }
          }
        }
      case "reveal":
        guard let filePath = arguments["path"] as? String else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "The file path is missing.",
              details: nil
            )
          )
          return
        }
        NSWorkspace.shared.activateFileViewerSelecting(
          [URL(fileURLWithPath: filePath)]
        )
        result(nil)
      case "createBookmark":
        guard let filePath = arguments["path"] as? String else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "The bookmark path is missing.",
              details: nil
            )
          )
          return
        }
        do {
          let bookmark = try URL(fileURLWithPath: filePath).bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          result(bookmark.base64EncodedString())
        } catch {
          result(
            FlutterError(
              code: "bookmark_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      case "startAccessingBookmark":
        guard
          let encodedBookmark = arguments["bookmark"] as? String,
          let bookmark = Data(base64Encoded: encodedBookmark)
        else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "The security-scoped bookmark is invalid.",
              details: nil
            )
          )
          return
        }
        do {
          var isStale = false
          let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
          )
          guard url.startAccessingSecurityScopedResource() else {
            result(
              FlutterError(
                code: "bookmark_access_denied",
                message: "macOS denied access to the selected file.",
                details: nil
              )
            )
            return
          }

          let token = UUID().uuidString
          self.securityScopedURLs[token] = url
          var response: [String: Any] = [
            "token": token,
            "path": url.path,
          ]
          if isStale {
            do {
              let refreshed = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
              )
              response["bookmark"] = refreshed.base64EncodedString()
            } catch {
              self.securityScopedURLs.removeValue(forKey: token)
              url.stopAccessingSecurityScopedResource()
              result(
                FlutterError(
                  code: "bookmark_failed",
                  message: error.localizedDescription,
                  details: nil
                )
              )
              return
            }
          }
          result(response)
        } catch {
          result(
            FlutterError(
              code: "bookmark_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      case "stopAccessingBookmark":
        guard let token = arguments["token"] as? String else {
          result(
            FlutterError(
              code: "invalid_arguments",
              message: "The security-scoped access token is missing.",
              details: nil
            )
          )
          return
        }
        if let url = self.securityScopedURLs.removeValue(forKey: token) {
          url.stopAccessingSecurityScopedResource()
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
