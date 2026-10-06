# CocoaPods can point at a subdirectory of a repository, which SPM cannot —
# that asymmetry is why SPM needs a subtree mirror and the pod does not.
# Sub-project 3 (the RN inversion) depends on this pod, because Expo modules
# are CocoaPods consumers.
Pod::Spec.new do |s|
  s.name             = 'Advenue'
  s.version          = '1.2.1'
  s.summary          = 'Advenue attribution SDK for iOS'
  s.description      = 'Open-source mobile measurement: attribution, sessions, in-app events.'
  s.homepage         = 'https://github.com/broverse/advenue'
  s.license          = { :type => 'MIT', :file => 'packages/sdk-swift/LICENSE' }
  s.author           = { 'Advenue' => 'support@advenue.io' }
  s.source           = { :git => 'https://github.com/broverse/advenue.git', :tag => "sdk-swift-v#{s.version}" }
  # The SDK is four SwiftPM modules that import each other; CocoaPods builds
  # one module, where those imports resolve to nothing. The script strips
  # them after download — the same strip the RN/Flutter vendor scripts apply.
  # `find` rather than a fixed path: prepare_command's working directory is
  # the checkout root, but that is one CocoaPods version's behavior, not a
  # contract, and this resolves from either the root or this directory.
  s.prepare_command = 'sh "$(find . -name strip-module-imports.sh | head -n 1)"'
  s.ios.deployment_target = '15.0'
  s.swift_version    = '6.0'
  # File patterns resolve from the repository root, not from this podspec's
  # directory — unprefixed, `pod spec lint` reports "did not match any file".
  s.source_files     = 'packages/sdk-swift/Sources/AdvenueCore/**/*.swift',
                       'packages/sdk-swift/Sources/AdvenuePlatform/**/*.swift',
                       'packages/sdk-swift/Sources/Advenue/**/*.swift'
end
