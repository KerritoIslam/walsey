// ignore_for_file: type_init_formals

/// How strongly a behavior is backed by evidence.
enum Evidence {
  /// Confirmed on the actual target controller by this project's own tests.
  hardwareConfirmed,

  /// Derived from decompiled vendor-app code (LED_UNION docs). Not yet seen
  /// working on the target device.
  decompiledApp,
}

enum Capability { power, color, brightness, effect }

/// Whether one capability is available, and why / how well-founded.
final class CapabilitySupport {
  const CapabilitySupport.supported(Evidence this.evidence)
      : unsupportedReason = null;
  const CapabilitySupport.unsupported(String this.unsupportedReason)
      : evidence = null;

  final Evidence? evidence;
  final String? unsupportedReason;

  bool get isSupported => evidence != null;
}

/// What a given controller can do. Unsupported entries carry a reason so the
/// UI and voice layers can report it instead of pretending a command worked.
final class DeviceCapabilities {
  const DeviceCapabilities(this._byCapability);

  /// Every capability unsupported for the same reason.
  factory DeviceCapabilities.noneBecause(String reason) => DeviceCapabilities({
        for (final c in Capability.values)
          c: CapabilitySupport.unsupported(reason),
      });

  final Map<Capability, CapabilitySupport> _byCapability;

  CapabilitySupport of(Capability c) =>
      _byCapability[c] ??
      const CapabilitySupport.unsupported('capability not modelled');
}
