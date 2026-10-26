require 'json'
package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name = 'BlePlx'
  s.version = package['version']
  s.summary = package['description']
  s.description = package['description']
  s.homepage = package['homepage']
  s.license = package['license']
  s.author = package['author']
  s.source = { :git => package['repository'], :tag => "v#{s.version}" }
  s.platforms = { :ios => '16.4' }
  s.swift_version = '5.10'
  s.static_framework = true
  s.source_files = '**/*.swift'
  s.dependency 'ExpoModulesCore'
  s.dependency 'MultiplatformBleAdapter', '0.2.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
