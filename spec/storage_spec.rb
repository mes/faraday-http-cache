require 'spec_helper'

describe Faraday::HttpCache::Storage do
  let(:cache_key) { 'bdde120549a0e4eaa55741ffb6de17faea5f88e9' }
  let(:request) do
    env = { method: :get, url: 'http://test/index' }
    double(env.merge(serializable_hash: env))
  end

  let(:response) { double(serializable_hash: {}) }

  let(:cache) { ActiveSupport::Cache.lookup_store }

  let(:storage) { Faraday::HttpCache::Storage.new(store: cache) }
  subject { storage }

  describe 'Cache configuration' do
    it 'uses a MemoryStore by default' do
      expect(Faraday::HttpCache::MemoryStore).to receive(:new).and_call_original
      Faraday::HttpCache::Storage.new
    end

    it 'lookups an ActiveSupport cache store if a Symbol is given' do
      expect(ActiveSupport::Cache).to receive(:lookup_store).with(:file_store, ['/tmp']).and_call_original
      Faraday::HttpCache::Storage.new(store: :file_store, store_options: ['/tmp'])
    end

    it 'emits a warning when doing the lookup of an ActiveSupport cache store' do
      logger = double
      expect(logger).to receive(:warn).with(/Passing a Symbol as the 'store' is deprecated/)
      Faraday::HttpCache::Storage.new(store: :file_store, logger: logger)
    end

    it 'raises an error when the given store is not valid' do
      wrong = double

      expect {
        Faraday::HttpCache::Storage.new(store: wrong)
      }.to raise_error(ArgumentError)
    end
  end

  describe 'storing responses' do
    shared_examples 'A storage with serialization' do
      it 'writes the response object to the underlying cache' do
        entry = [serializer.dump(request.serializable_hash), serializer.dump(response.serializable_hash)]
        expect(cache).to receive(:write).with(cache_key, [entry])
        subject.write(request, response)
      end
    end

    context 'with the JSON serializer' do
      let(:serializer) { JSON }
      it_behaves_like 'A storage with serialization'

      context 'when ASCII characters in response cannot be converted to UTF-8' do
        let(:response) do
          body = "\u2665".force_encoding('ASCII-8BIT')
          double(:response, serializable_hash: { 'body' => body })
        end

        it 'raises and logs a warning' do
          logger = double(:logger, warn: nil)
          storage = Faraday::HttpCache::Storage.new(logger: logger)

          expect { storage.write(request, response) }.to raise_error
          expect(logger).to have_received(:warn).with(
            'Response could not be serialized: "\xE2" from ASCII-8BIT to UTF-8. Try using Marshal to serialize.'
          )
        end
      end
    end

    context 'with the Marshal serializer' do
      let(:serializer) { Marshal }
      let(:storage) { Faraday::HttpCache::Storage.new(store: cache, serializer: Marshal) }

      it_behaves_like 'A storage with serialization'
    end
  end

  describe 'reading responses' do
    it 'returns nil if the response is not cached' do
      expect(subject.read(request)).to be_nil
    end

    it 'decodes a stored response' do
      subject.write(request, response)

      expect(subject.read(request)).to be_a(Faraday::HttpCache::Response)
    end
  end

  describe 'remove age before caching and normalize max-age if non-zero age present' do
    it 'is fresh if the response still has some time to live' do
      headers = {
          'Age' => 6,
          'Cache-Control' => 'public, max-age=40',
          'Date' => (Time.now - 38).httpdate,
          'Expires' => (Time.now - 37).httpdate,
          'Last-Modified' => (Time.now - 300).httpdate
      }
      response = Faraday::HttpCache::Response.new(response_headers: headers)
      expect(response).to be_fresh
      subject.write(request, response)

      cached_response = subject.read(request)
      expect(cached_response.max_age).to eq(34)
      expect(cached_response).not_to be_fresh
    end

    it 'is fresh until cached and that 1 second elapses then the response is no longer fresh' do
      headers = {
          'Date' => (Time.now - 39).httpdate,
          'Expires' => (Time.now + 40).httpdate,
      }

      response = Faraday::HttpCache::Response.new(response_headers: headers)
      expect(response).to be_fresh
      subject.write(request, response)

      sleep(1)
      cached_response = subject.read(request)
      expect(cached_response).not_to be_fresh
    end
  end

end
