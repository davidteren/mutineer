# frozen_string_literal: true

# The boot file loads or registers the classes (#493).
RSpec.describe "LanguageProduct" do
  it "strips the value" do
    expect(LanguageProduct.new(" en ").language).to eq("en")
  end

  it "rejects upper case" do
    expect(LanguageProduct.new("EN").errors).to eq([:invalid])
  end

  it "rejects a long value" do
    expect(LanguageProduct.new("a" * 36).errors).to eq([:too_long])
  end

  it "has a label" do
    expect(LanguageProduct.new("en").label).to eq("product")
  end
end
