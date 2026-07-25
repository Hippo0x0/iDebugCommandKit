Pod::Spec.new do |spec|
  spec.name         = 'DebugCommandKit'
  spec.version      = '0.1.0'
  spec.summary      = 'DEBUG-only local UIKit command server for iOS apps.'
  spec.description  = <<-DESC
    A DEBUG-only, loopback-only command server for inspecting and driving a
    UIKit app during development. It provides view-tree inspection, screenshots,
    control activation, scrolling, text entry, and app-defined debug commands.
  DESC
  spec.homepage     = 'https://github.com/Hippo0x0/DebugCommandKit'
  spec.license      = { :type => 'MIT', :file => 'LICENSE' }
  spec.author       = { 'Copytain' => 'hippo0x0@gmail.com' }
  spec.source       = { :git => 'https://github.com/Hippo0x0/DebugCommandKit.git', :tag => spec.version.to_s }

  spec.platform     = :ios, '16.0'
  spec.swift_versions = ['5.9', '6.0']
  spec.source_files = 'Sources/DebugCommandKit/**/*.swift'
  spec.frameworks   = 'Foundation', 'UIKit'
  spec.pod_target_xcconfig = {
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]' => '$(inherited) DEBUG_COMMAND_KIT'
  }
end
