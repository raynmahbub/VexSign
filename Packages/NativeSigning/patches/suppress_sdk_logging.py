"""Narrow overlay on hash-checked upstream logging source; no stdout redirection."""
import re


def suppress_logging(text, package):
    if package not in ('sidesign', 'anisettekit'):
        raise ValueError('Unexpected logging package')
    enum_name = 'SideSignLogging' if package == 'sidesign' else 'AnisetteKitLogging'
    if package == 'sidesign':
        disable = 'AnisetteKitLogging.setLogging(false)'
        marker = 'VexSignAnisettePrivacy.loggingSuppressed'
    else:
        disable = '''anisetteCoreSetLogging(0)
        #if os(Windows)
        _putenv("UNICORN_LOG_LEVEL=0")
        #else
        setenv("UNICORN_LOG_LEVEL", "0", 1)
        #endif'''
        marker = 'true'
    replacement = '''public enum %s {
    public static var isLoggingEnabled: Bool { false }
    public static func setLogging(_ enabled: Bool) {
        %s
    }
}''' % (enum_name, disable)
    text, count = re.subn(r'^public enum ' + enum_name + r' \{.*?^\}', lambda _: replacement, text,
                          flags=re.MULTILINE | re.DOTALL)
    if count != 1:
        raise ValueError('Logging configuration shape changed')
    for function in ('debugLog', 'verboseLog'):
        pattern = r'^public func ' + function + r'\(_ text: @autoclosure \(\) -> String\) \{.*?^\}'
        replacement = 'public func ' + function + '(_ text: @autoclosure () -> String) {\n    // VexSign privacy overlay: never evaluate or emit the message.\n}'
        text, count = re.subn(pattern, lambda _: replacement, text, flags=re.MULTILINE | re.DOTALL)
        if count != 1:
            raise ValueError('Logging function shape changed')
    name = 'VexSignSideSignPrivacy' if package == 'sidesign' else 'VexSignAnisettePrivacy'
    return text + '\n// VexSign build-time privacy-overlay marker.\npublic enum ' + name + ' {\n    public static var loggingSuppressed: Bool { ' + marker + ' }\n}\n'
