# spec/adapters/openrouter_adapter_spec.rb
require "maciekos/openrouter_adapter"
RSpec.describe Maciekos::OpenRouterAdapter do
  it "computes deterministic signature" do
    adapter = described_class.new
    s1 = adapter.send(:deterministic_signature, "m1", "p", "t")
    s2 = adapter.send(:deterministic_signature, "m1", "p", "t")
    expect(s1).to eq(s2)
  end
end

