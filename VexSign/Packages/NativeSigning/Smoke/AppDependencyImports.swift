// Compile the app's package products in the same candidate as the native backend.
// This is not the app entry point and never starts servers, signs or logs in.
import Vapor
import NIOSSL
import NukeUI
import NimbleExtensions
import NimbleJSON
import NimbleViews
import AltSourceKit
import Zip
import SWCompression
import ZIPFoundation
import IDevice
import IDeviceSwift

public enum CombinedDependencyProbe {
    public static let scope = "Dependency compilation only; not an enabled account or signing capability"
}
