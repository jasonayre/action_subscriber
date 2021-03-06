require "active_support"
require "active_support/core_ext"
if ::RUBY_PLATFORM == "java"
  require 'march_hare'
else
  require "bunny"
end
require "lifeguard"
require "middleware"
require "thread"

require "action_subscriber/version"

# Preload will load configuration and logging. These are the things
# that the bin stub need to initialize the configuration before load
# hooks are run when the app loads.
require "action_subscriber/preload"

require "action_subscriber/default_routing"
require "action_subscriber/dsl"
require "action_subscriber/message_retry"
require "action_subscriber/middleware"
require "action_subscriber/rabbit_connection"
require "action_subscriber/subscribable"
require "action_subscriber/bunny/subscriber"
require "action_subscriber/march_hare/subscriber"
require "action_subscriber/babou"
require "action_subscriber/publisher"
require "action_subscriber/publisher/async"
require "action_subscriber/route"
require "action_subscriber/route_set"
require "action_subscriber/router"
require "action_subscriber/threadpool"
require "action_subscriber/base"

module ActionSubscriber
  ##
  # Public Class Methods
  #

  # Loop over all subscribers and pull messages if there are
  # any waiting in the queue for us.
  #
  def self.auto_pop!
    return if ::ActionSubscriber::Threadpool.busy?
    route_set.auto_pop!
  end

  # Loop over all subscribers and register each as
  # a subscriber.
  #
  def self.auto_subscribe!
    route_set.auto_subscribe!
  end

  def self.configure
    yield(configuration) if block_given?
  end

  def self.draw_routes(&block)
    fail "No block provided to ActionSubscriber.draw_routes" unless block_given?

    # We need to delay the execution of this block because ActionSubscriber is
    # not configured at this point if we're calling from within the required app.
    @route_set = nil
    @draw_routes_block = block
  end

  def self.print_subscriptions
    logger.info configuration.inspect
    route_set.routes.group_by(&:subscriber).each do |subscriber, routes|
      logger.info subscriber.name
      routes.each do |route|
        logger.info "  -- method: #{route.action}"
        logger.info "    --    exchange: #{route.exchange}"
        logger.info "    --       queue: #{route.queue}"
        logger.info "    -- routing_key: #{route.routing_key}"
        logger.info "    --  threadpool: #{route.threadpool.name}, pool_size: #{route.threadpool.pool_size}"
      end
    end
  end

  def self.setup_queues!
    route_set.setup_queues!
  end

  def self.start_queues
    ::ActionSubscriber::RabbitConnection.subscriber_connection
    setup_queues!
    print_subscriptions
  end

  def self.start_subscribers
    ::ActionSubscriber::RabbitConnection.subscriber_connection
    setup_queues!
    auto_subscribe!
    print_subscriptions
  end

  def self.stop_subscribers!
    route_set.cancel_consumers!
  end

  # Execution is delayed until after app loads when used with bin/action_subscriber
  require "action_subscriber/railtie" if defined?(Rails)
  ::ActiveSupport.run_load_hooks(:action_subscriber, Base)

  # Intialize async publisher adapter
  ::ActionSubscriber::Publisher::Async.publisher_adapter

  ##
  # Private Implementation
  #
  def self.route_set
    @route_set ||= begin
      if @draw_routes_block
        routes = Router.draw_routes(&@draw_routes_block)
        RouteSet.new(routes)
      else
        logger.warn "DEPRECATION WARNING: We are inferring your routes by looking at your subscribers. This behavior is deprecated and will be removed in version 2.0. Please see the routing guide at https://github.com/mxenabled/action_subscriber/blob/master/routing.md"
        RouteSet.new(self.send(:default_routes))
      end
    end
  end
  private_class_method :route_set

  def self.default_routes
    ::ActionSubscriber::Base.inherited_classes.flat_map do |klass|
      klass.routes
    end
  end
  private_class_method :default_routes
end

at_exit do
  ::ActionSubscriber::Publisher::Async.publisher_adapter.shutdown!
  ::ActionSubscriber::RabbitConnection.publisher_disconnect!
end
