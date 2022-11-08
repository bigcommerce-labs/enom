Gem::Specification.new do |s|
  s.name = "enom"
  s.version = "1.3.0"
  s.authors = ["James Miller"]
  s.summary = %q{Ruby wrapper for the Enom API}
  s.description = %q{Enom is a Ruby wrapper and command line interface for portions of the Enom domain reseller API.}
  s.homepage = "http://github.com/bensie/enom"
  s.email = "bensie@gmail.com"
  s.files  = %w( README.md Rakefile LICENSE ) + ["lib/enom.rb"] + Dir.glob("lib/enom/*.rb") + Dir.glob("lib/enom/commands/*.rb") + Dir.glob("test/**/*") + Dir.glob("bin/*")
  s.has_rdoc = false
  s.add_dependency "httparty", "~> 0.15"
  s.add_dependency "public_suffix", "~> 5.0.0"
  s.add_dependency "activesupport", "> 4.2"
  s.add_development_dependency "test-unit"
  s.add_development_dependency "shoulda", "~> 3.5"
  # chrisk is updating fakeweb, but hasn't released a gem yet - see https://github.com/chrisk/fakeweb/issues/57#issuecomment-325515168
  # Once a gem is released, remove the line in the Gemfile and uncomment this one
  # s.add_development_dependency "fakeweb"
  s.add_development_dependency "rake", "~> 12.0"
  s.executables = %w(enom)
  s.default_executable = "enom"
end
