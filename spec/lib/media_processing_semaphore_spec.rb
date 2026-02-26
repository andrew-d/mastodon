# frozen_string_literal: true

require 'rails_helper'

describe MediaProcessingSemaphore do
  after do
    # Reset memoized semaphore between tests
    described_class.remove_instance_variable(:@semaphore) if described_class.instance_variable_defined?(:@semaphore)
  end

  describe '.acquire' do
    it 'yields the block' do
      expect { |b| described_class.acquire(&b) }.to yield_control
    end

    it 'returns the block result' do
      result = described_class.acquire { 42 }
      expect(result).to eq(42)
    end

    it 'emits a success increment via statsd' do
      events = []
      callback = ->(_name, _start, _finish, _id, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, 'increment.statsd') do
        described_class.acquire { true }
      end

      expect(events).to include(a_hash_including(key: 'media_processing.semaphore.success'))
    end

    it 'emits a duration timing via statsd' do
      events = []
      callback = ->(_name, _start, _finish, _id, payload) { events << payload }
      ActiveSupport::Notifications.subscribed(callback, 'timing.statsd') do
        described_class.acquire { true }
      end

      expect(events).to include(a_hash_including(key: 'media_processing.semaphore.duration'))
    end

    context 'when semaphore permits are exhausted' do
      around do |example|
        ClimateControl.modify MEDIA_PROCESSING_CONCURRENCY: '1', MEDIA_PROCESSING_TIMEOUT: '1' do
          example.run
        end
      end

      it 'raises MediaProcessingTimeoutError when timeout expires' do
        barrier = Concurrent::CyclicBarrier.new(2)

        thread = Thread.new do
          described_class.acquire do
            barrier.wait(5)
            sleep 2
          end
        end

        barrier.wait(5)

        expect { described_class.acquire { true } }.to raise_error(Mastodon::MediaProcessingTimeoutError)

        thread.join
      end

      it 'emits a timeout increment via statsd' do
        barrier = Concurrent::CyclicBarrier.new(2)

        thread = Thread.new do
          described_class.acquire do
            barrier.wait(5)
            sleep 2
          end
        end

        barrier.wait(5)

        events = []
        callback = ->(_name, _start, _finish, _id, payload) { events << payload }
        ActiveSupport::Notifications.subscribed(callback, 'increment.statsd') do
          suppress(Mastodon::MediaProcessingTimeoutError) do
            described_class.acquire { true }
          end
        end

        expect(events).to include(a_hash_including(key: 'media_processing.semaphore.timeout'))

        thread.join
      end
    end

    context 'when permits is 0' do
      around do |example|
        ClimateControl.modify MEDIA_PROCESSING_CONCURRENCY: '0' do
          example.run
        end
      end

      it 'skips the semaphore and yields directly' do
        expect { |b| described_class.acquire(&b) }.to yield_control
      end
    end

    context 'when running in Sidekiq server' do
      before do
        stub_const('Sidekiq::CLI', Class.new)
        allow(Sidekiq).to receive(:server?).and_return(true)
      end

      it 'skips the semaphore and yields directly' do
        expect { |b| described_class.acquire(&b) }.to yield_control
      end
    end

    it 'releases the permit after the block completes' do
      described_class.acquire { true }
      # Should not raise — permit was released
      expect { described_class.acquire { true } }.to_not raise_error
    end

    it 'releases the permit when the block raises' do
      suppress(RuntimeError) do
        described_class.acquire { raise 'boom' }
      end

      expect { described_class.acquire { true } }.to_not raise_error
    end
  end
end
