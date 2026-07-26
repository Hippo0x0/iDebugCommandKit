Pod::Spec.new do |spec|
  spec.name         = 'iDebugCommandKit'
  spec.version      = '1.0.1'
  spec.summary      = 'DEBUG-only local UIKit command server for iOS apps.'
  spec.description  = <<-DESC
    A DEBUG-only, loopback-only command server for inspecting and driving a
    UIKit app during development. It provides view-tree inspection, screenshots,
    control activation, scrolling, text entry, and app-defined debug commands.
  DESC
  spec.homepage     = 'https://github.com/Hippo0x0/iDebugCommandKit'
  spec.license      = { :type => 'MIT', :file => 'LICENSE' }
  spec.author       = { 'Copytain' => 'hippo0x0@gmail.com' }
  spec.source       = { :git => 'https://github.com/Hippo0x0/iDebugCommandKit.git', :tag => spec.version.to_s }

  spec.platform     = :ios, '13.0'
  spec.swift_versions = ['5.7', '5.8', '5.9', '6.0']
  spec.source_files = 'Sources/iDebugCommandKit/**/*.swift'
  spec.frameworks   = 'Foundation', 'UIKit'
  spec.pod_target_xcconfig = {
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]' => '$(inherited) I_DEBUG_COMMAND_KIT'
  }
end
