# coding: utf-8
version = File.read(File.expand_path('../../BOSH_VERSION', __FILE__)).strip

Gem::Specification.new do |spec|
  spec.name          = 'bosh-stemcell'
  spec.version       = version
  spec.authors       = 'Pivotal'
  spec.email         = 'support@cloudfoundry.com'
  spec.description   = 'Bosh::Stemcell provides tools to manage stemcells'
  spec.summary       = 'Bosh::Stemcell provides tools to manage stemcells'
  spec.homepage      = 'https://github.com/cloudfoundry/bosh'
  spec.license       = 'Apache 2.0'

  spec.required_ruby_version = Gem::Requirement.new('>= 1.9.3')

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = %w[lib]

  spec.add_dependency 'bosh_aws_cpi', "~>#{version}"
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec'
  spec.add_development_dependency 'rspec-fire'
  spec.add_development_dependency 'timecop'
  spec.add_development_dependency 'serverspec'
  spec.add_development_dependency 'foodcritic'
end
