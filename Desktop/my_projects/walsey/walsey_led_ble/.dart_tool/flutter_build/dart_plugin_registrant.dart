//
// Generated file. Do not edit.
// This file is generated from template in file `flutter_tools/lib/src/flutter_plugins.dart`.
//

// @dart = 3.3

import 'dart:io'; // flutter_ignore: dart_io_import.
import 'package:bluetooth_low_energy_android/bluetooth_low_energy_android.dart' as bluetooth_low_energy_android;
import 'package:bluetooth_low_energy_darwin/bluetooth_low_energy_darwin.dart' as bluetooth_low_energy_darwin;
import 'package:bluetooth_low_energy_linux/bluetooth_low_energy_linux.dart' as bluetooth_low_energy_linux;
import 'package:device_info_plus/device_info_plus.dart' as device_info_plus;
import 'package:bluetooth_low_energy_darwin/bluetooth_low_energy_darwin.dart' as bluetooth_low_energy_darwin;
import 'package:bluetooth_low_energy_windows/bluetooth_low_energy_windows.dart' as bluetooth_low_energy_windows;
import 'package:device_info_plus/device_info_plus.dart' as device_info_plus;

@pragma('vm:entry-point')
class _PluginRegistrant {

  @pragma('vm:entry-point')
  static void register() {
    if (Platform.isAndroid) {
      try {
        bluetooth_low_energy_android.BluetoothLowEnergyAndroidPlugin.registerWith();
      } catch (err) {
        print(
          '`bluetooth_low_energy_android` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

    } else if (Platform.isIOS) {
      try {
        bluetooth_low_energy_darwin.BluetoothLowEnergyDarwinPlugin.registerWith();
      } catch (err) {
        print(
          '`bluetooth_low_energy_darwin` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

    } else if (Platform.isLinux) {
      try {
        bluetooth_low_energy_linux.BluetoothLowEnergyLinuxPlugin.registerWith();
      } catch (err) {
        print(
          '`bluetooth_low_energy_linux` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

      try {
        device_info_plus.DeviceInfoPlusLinuxPlugin.registerWith();
      } catch (err) {
        print(
          '`device_info_plus` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

    } else if (Platform.isMacOS) {
      try {
        bluetooth_low_energy_darwin.BluetoothLowEnergyDarwinPlugin.registerWith();
      } catch (err) {
        print(
          '`bluetooth_low_energy_darwin` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

    } else if (Platform.isWindows) {
      try {
        bluetooth_low_energy_windows.BluetoothLowEnergyWindowsPlugin.registerWith();
      } catch (err) {
        print(
          '`bluetooth_low_energy_windows` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

      try {
        device_info_plus.DeviceInfoPlusWindowsPlugin.registerWith();
      } catch (err) {
        print(
          '`device_info_plus` threw an error: $err. '
          'The app may not function as expected until you remove this plugin from pubspec.yaml'
        );
      }

    }
  }
}
