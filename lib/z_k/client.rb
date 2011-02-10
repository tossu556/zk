module ZK
  # a more ruby-friendly wrapper around the low-level drivers
  #
  class Client
    extend Forwardable

    attr_reader :event_handler

    # for backwards compatibility
    alias :watcher :event_handler #:nodoc:

    def initialize(connection, opts={})
      @cnx = connection
      @event_handler = EventHandler.new(self)
    end

    def closed?
      @cnx.state and false
    rescue RuntimeError => e
      # gah, lame error parsing here
      raise e unless e.message == 'zookeeper handle is closed'
      true
    end

    def connected?
      wrap_state_closed_error { @cnx.connected? }
    end

    def associating?
      wrap_state_closed_error { @cnx.associating? }
    end

    def connecting?
      wrap_state_closed_error { @cnx.connecting? }
    end

    def create(path, data='', opts={})
      # ephemeral is the default mode for us

      h = { :path => path, :data => data, :ephemeral => true, :sequence => false }.merge(opts)

      case mode = h.delete(:mode)
      when :ephemeral_sequential
        h[:ephemeral] = h[:sequence] = true
      when :persistent_sequential
        h[:ephemeral] = false
        h[:sequence] = true
      when :persistent
        h[:ephemeral] = false
      end

      rv = check_rc(@cnx.create(h))
      opts[:callback] ? rv : rv[:path]
    end

    # TODO: improve callback handling
    def get(path, opts={})
      h = { :path => path }.merge(opts)

      setup_watcher(h)

      rv = check_rc(@cnx.get(h))

      opts[:callback] ? rv : rv.values_at(:data, :stat)
    end

    def set(path, data, opts={})
      h = { :path => path, :data => data }.merge(opts)

      rv = check_rc(@cnx.set(h))

      opts[:callback] ? nil : rv[:stat]
    end

    def stat(path, opts={})
      h = { :path => path }.merge(opts)

      setup_watcher(h)

      check_rc(@cnx.stat(h))[:stat]
    rescue Exceptions::NoNode
    end

    alias :exists? :stat

    def close!
      wrap_state_closed_error { @cnx.close }
    end

    # TODO: improve callback handling
    def delete(path, opts={})
      h = { :path => path, :version => -1 }.merge(opts)
      rv = check_rc(@cnx.delete(h))
      nil
    end

    def children(path, opts={})
      h = { :path => path }.merge(opts)

      setup_watcher(h)

      rv = check_rc(@cnx.get_children(h))
      opts[:callback] ? nil : rv[:children]
    end

    def get_acl(path, opts={})
      h = { :path => path }.merge(opts)
      rv = check_rc(@cnx.get_acl(h))
      opts[:callback] ? nil : rv.values_at(:children, :stat)
    end

    def set_acl(path, acls, opts={})
      h = { :path => path, :acl => acls }.merge(opts)
      rv = check_rc(@cnx.set_acl(h))
      opts[:callback] ? nil : rv[:stat]
    end

    #--
    #
    # EXTENSIONS
    #
    # convenience methods for dealing with zookeeper (rm -rf, mkdir -p, etc)
    #
    #++
    
    # creates all parent paths and 'path' in zookeeper as nodes with zero data
    # opts should be valid options to ZooKeeper#create
    #---
    # TODO: write a non-recursive version of this. ruby doesn't have TCO, so
    # this could get expensive w/ psychotically long paths
    #
    def mkdir_p(path)
      create(path, '', :mode => :persistent)
    rescue Exceptions::NodeExists
      return
    rescue Exceptions::NoNode
      if File.dirname(path) == '/'
        # ok, we're screwed, blow up
        raise KeeperException, "could not create '/', something is wrong", caller
      end

      mkdir_p(File.dirname(path))
      retry
    end

    # recursively remove all children of path then remove path itself
    def rm_rf(paths)
      Array(paths).flatten.each do |path|
        begin
          children(path).each do |child|
            rm_rf(File.join(path, child))
          end

          delete(path)
          nil
        rescue Exceptions::NoNode
        end
      end
    end

    # will block the caller until +abs_node_path+ has been removed
    def block_until_node_deleted(abs_node_path)
      queue = Queue.new

      node_deletion_cb = lambda do
        unless exists?(abs_node_path, :watch => true)
          queue << :locked
        end
      end

      watcher.register(abs_node_path, &node_deletion_cb)
      node_deletion_cb.call

      queue.pop # block waiting for node deletion
      true
    end

    # creates a new locker based on the name you send in
    # @param [String] name the name of the lock you wish to use
    # @see ZooKeeper::Locker#initialize
    # @return ZooKeeper::Locker the lock using this connection and name
    # @example
    #   zk.locker("blah").lock!
    def locker(name)
      Locker.new(self, name)
    end

    # convenience method for acquiring a lock then executing a code block
    def with_lock(path, &b)
      locker(path).with_lock(&b)
    end

    protected
      def wrap_state_closed_error
        yield
      rescue RuntimeError => e
        # gah, lame error parsing here
        raise e unless e.message == 'zookeeper handle is closed'
        false
      end

      def setup_watcher(opts)
        opts[:watcher] = watcher_callback if opts.delete(:watch)
      end

      def watcher_callback
        ZookeeperCallbacks::WatcherCallback.create { |event| @event_handler.process(event) }
      end

      def check_rc(hash)
        hash.tap do |h|
          if code = h[:rc]
            raise Exceptions::KeeperException.by_code(code) unless code == Zookeeper::ZOK
          end
        end
      end
  end
end
