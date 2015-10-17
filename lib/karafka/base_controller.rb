# Karafka module namespace
module Karafka
  # Base controller from which all Karafka controllers should inherit
  # Similar to Rails controllers we can define before_enqueue callbacks
  # that will be executed
  # Note that if before_enqueue return false, the chain will be stopped and
  # the perform method won't be executed in sidekiq (won't peform_async it)
  # @example Create simple controller
  #   class ExamplesController < Karafka::BaseController
  #     def perform
  #       # some logic here
  #     end
  #   end
  #
  # @example Create a controller with a block before_enqueue
  #   class ExampleController < Karafka::BaseController
  #
  #     before_enqueue do
  #       # Here we should have some checking logic
  #       # If false is returned, won't schedule a perform action
  #     end
  #
  #     def perform
  #       # some logic here
  #     end
  #   end
  #
  # @example Create a controller with a method before_enqueue and topic
  #   class ExampleController < Karafka::BaseController
  #     self.topic = :kafka_topic
  #
  #     before_enqueue :before_method
  #
  #     def perform
  #       # some logic here
  #     end
  #
  #     private
  #
  #     def before_method
  #       # Here we should have some checking logic
  #       # If false is returned, won't schedule a perform action
  #     end
  #   end
  #
  # @example Create a controller with an after_failure action, topic and group
  #   class ExampleController < Karafka::BaseController
  #     self.group = :kafka_group_name
  #     self.topic = :kafka_topic
  #
  #     def perform
  #       # some logic here
  #     end
  #
  #     def after_failure
  #       # action taken in case perform fails
  #     end
  #   end
  #
  # @example Create a controller with a custom Sidekiq worker assigned
  #   class ExampleController < Karafka::BaseController
  #     self.worker = MyAppMainWorker
  #
  #     def perform
  #       # some logic here
  #     end
  #   end
  class BaseController
    include ActiveSupport::Callbacks

    attr_reader :params

    # The call method is wrapped with a set of callbacks
    # We won't run perform at the backend if any of the callbacks
    # returns false
    # @see http://api.rubyonrails.org/classes/ActiveSupport/Callbacks/ClassMethods.html#method-i-get_callbacks
    define_callbacks :call,
      terminator: ->(_target, result) { result == false }

    class << self
      # Group can be set or it will be autogenerated upon first use
      attr_writer :group, :topic, :worker

      # @return [String, Symbol] group name for Kafka
      # @note If not set via self.group = 'group_name' it will be autogenerated based on
      #   the name and current controller topic
      def group
        @group ||= "#{Karafka::App.config.name.underscore}_#{topic}"
      end

      # @return [String, Symbol] topic on which we should listen for incoming messages
      # @note If not set via self.topic = 'topic_name' it will be autogenerated based on
      #   the controller name (including namespaces)
      def topic
        @topic ||= to_s.underscore.sub('_controller', '').tr('/', '_')
      end

      # @return [Class] worker class to which we should schedule Sidekiq bg stuff
      # @note We use builder and conditionally assing, because we want to leave to users
      #   a possibility to use their own workers that don't inherit
      #   from Karafka::Workers::BaseWorker
      def worker
        @worker ||= Karafka::Workers::Builder.new(self).build
      end

      # Creates a callback that will be executed before scheduling to Sidekiq
      # @param method_name [Symbol, String] method name or nil if we plan to provide a block
      # @yield A block with a code that should be executed before scheduling
      # @note If value returned is false, will chalt the chain and not schedlue to Sidekiq
      # @example Define a block before_enqueue callback
      #   before_enqueue do
      #     # logic here
      #   end
      #
      # @example Define a class name before_enqueue callback
      #   before_enqueue :method_name
      def before_enqueue(method_name = nil, &block)
        Karafka.logger.debug("Defining before_enqueue filter with #{block}")
        set_callback :call, :before, method_name ? method_name : block
      end
    end

    # @raise [Karafka::Errors::TopicNotDefined] raised if we didn't define kafka topic
    # @raise [Karafka::Errors::PerformMethodNotDefined] raised if we
    #   didn't define the perform method
    def initialize
      fail Errors::TopicNotDefined unless self.class.topic
      fail Errors::PerformMethodNotDefined unless self.respond_to?(:perform)
    end

    # Assigns parameters hash (Karafka::Params) internally. It also adds some extra
    #  flavour values to it
    # @param params [Karafka::Params] params instance
    def params=(params)
      @params = params.tap do |param|
        param.merge!(
          controller: self.class,
          topic: self.class.topic,
          worker: self.class.worker
        )
      end
    end

    # Executes the default controller flow, runs callbacks and if not halted
    # will schedule a perform task in sidekiq
    def call
      run_callbacks :call do
        enqueue
      end
    end

    private

    # Enqueues the execution of perform method into sidekiq worker
    def enqueue
      Karafka.logger.info("Enqueuing #{self.class} - #{params} into #{self.class.worker}")
      self.class.worker.perform_async(params)
    end
  end
end
