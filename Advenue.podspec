# CocoaPods can point at a subdirectory of a repository, which SPM cannot —
# that asymmetry is why SPM needs a subtree mirror and the pod does not.
# Sub-project 3 (the RN inversion) depends on this pod, because Expo modules
# are CocoaPods consumers.
Pod::Spec.new do |s|
  s.name             = 'Advenue'
  s.version          = '1.1.0'
  s.summary          = 'Advenue attribution SDK for iOS'
  s.description      = 'Open-source mobile measurement: attribution, sessions, in-app events.'
  s.homepage         = 'https://github.com/advenue/advenue'
  s.license          = { :type => 'AGPL-3.0', :file => 'LICENSE' }
  s.author           = { 'Advenue' => 'support@advenue.io' }
  s.source           = { :git => 'https://github.com/advenue/advenue.git', :tag => "sdk-swift-v#{s.version}" }
  s.ios.deployment_target = '15.0'
  s.swift_version    = '6.0'
  s.source_files     = 'Sources/AdvenueCore/**/*.swift',
                       'Sources/AdvenuePlatform/**/*.swift',
                       'Sources/Advenue/**/*.swift'
end
