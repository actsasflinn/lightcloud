require File.join(File.dirname(__FILE__), 'spec_base')

describe LightCloud do
  before do
    @valid_servers = {
      'lookup1_A' => ['127.0.0.1:1234', '127.0.0.1:4567'],
      'storage1_A' => ['127.0.0.2:1234', '127.0.0.2:4567']
    }

    @valid_lookup_nodes, @valid_storage_nodes = LightCloud.generate_nodes(@valid_servers)

    @generic_node = mock(TyrantNode)
    [:get, :set, :delete].each do |meth|
      @generic_node.stub!(meth).and_return(nil)
    end

    @nodes = [mock(TyrantNode), mock(TyrantNode), mock(TyrantNode)]
    @lookup_valid_node = mock(TyrantNode)
    @storage_valid_node = mock(TyrantNode)
      
    (@nodes + [@lookup_valid_node, @storage_valid_node]).each do |node|
      node.stub!(:get).and_return(nil)
      node.stub!(:set).and_return(nil)
      node.stub!(:delete).and_return(nil)
      node.stub!(:to_s).and_return(nil)
    end

    @storage_valid_node.stub!(:to_s).and_return('storage_valid_node')
      
    @lookup_ring = mock(HashRing)
    @lookup_ring.stub!(:iterate_nodes).and_return(@nodes)
    @lookup_ring.stub!(:get_node).and_return(@lookup_valid_node)
      
    @storage_ring = mock(HashRing)
    @storage_ring.stub!(:get_node).and_return(@storage_valid_node)

    @cloud = LightCloud.new
    @cloud.stub!(:get_lookup_ring).and_return(@lookup_ring)
    @cloud.stub!(:get_storage_ring).and_return(@storage_ring)
    @cloud.stub!(:get_storage_node).and_return(@storage_valid_node)
  end

  describe "node generation" do
    it "should split lookup and storage nodes into their own arrays" do
      lookup, storage = LightCloud.generate_nodes(@valid_servers)

      lookup.should be_has_key('lookup1_A')
      storage.should be_has_key('storage1_A')
    end

    it "should ignore configuration without 'lookup' or 'storage' in it" do
      @valid_servers['foobarbaz'] = []

      lookup, storage = LightCloud.generate_nodes(@valid_servers)

      lookup.should_not be_has_key('foobarbaz')
      storage.should_not be_has_key('foobarbaz')      
    end
  end

  describe "ring generation" do
    it "should create a TyrantNode for each node" do
      TyrantNode.should_receive(:new).with('lookup1_A', anything).once
      TyrantNode.should_receive(:new).with('storage1_A', anything).once
      
      LightCloud.init(@valid_lookup_nodes, @valid_storage_nodes)
    end

    it "should return the tyrant nodes as a name to node hash" do
      unneeded, name_to_nodes = @cloud.generate_ring(@valid_lookup_nodes)

      name_to_nodes.should be_has_key('lookup1_A')
      name_to_nodes['lookup1_A'].should be_kind_of(TyrantNode)
    end

    it "should return a hash ring with the nodes" do
      ring, unneeded = @cloud.generate_ring(@valid_lookup_nodes)

      ring.should be_kind_of(HashRing)
    end
  end

  describe "lookup cloud methods" do
    before do
      @key = 'foo'
      @storage_node = 'bar'
    end

    describe "locating or initting a storage node by key" do
      after do
        @cloud.should_receive(:locate_node).with(@key, anything).once.and_return(@storage_node)
        @cloud.locate_node_or_init(@key, LightCloud::DEFAULT_SYSTEM)
      end

      it "should just return the storage node if it was found" do
        @cloud.should_not_receive(:get_storage_ring)
        @cloud.should_not_receive(:get_lookup_ring)
      end

      it "should set the lookup ring to point to the new storage node if no previous storage node was found" do
        @storage_node = nil
        
        @storage_ring.should_receive(:get_node).with(@key).once.and_return(@storage_valid_node)
        @lookup_valid_node.should_receive(:set).with(@key, @storage_valid_node.to_s).once
      end
    end

    describe "locating a storage node by key" do
      it "should return the storage node if the key is found in the lookup ring" do    
        @nodes[0].should_receive(:get).with(@key).and_return(@storage_node)
        @cloud.should_receive(:get_storage_node).with(@storage_node, anything).once

        @cloud.locate_node(@key)
      end

      it "should return nil if the key doesn't exist in the lookup ring" do
        @cloud.locate_node(@key).should be_nil
      end

      it "should attempt to clean up the lookup ring if the value is NOT found in the first node" do
        @nodes[1].should_receive(:get).with(@key).and_return(@storage_node)
        @cloud.should_not_receive(:get_storage_node)
        @cloud.should_receive(:_clean_up_ring).with(@key, @storage_node, anything).once

        @cloud.locate_node(@key)
      end
    end

    describe "cleaning the lookup ring" do
      after do
        @cloud._clean_up_ring(@key, @storage_node, LightCloud::DEFAULT_SYSTEM)
      end

      it "should set the key/value onto the first node (index 0)" do
        @nodes[0].should_receive(:set).with(@key, @storage_node).once
      end

      it "should delete the key from the second node (index 1)" do
        @nodes[1].should_receive(:delete).with(@key).once
      end

      it "should not touch any other nodes" do
        @nodes[2].should_not_receive(:get)
        @nodes[2].should_not_receive(:set)
        @nodes[2].should_not_receive(:delete)
      end
      
      it "should return the storage node lookup" do
        @cloud.should_receive(:get_storage_node).with(@storage_node, anything).once
      end
    end
  end

  describe "setting" do
    before do
      @key = 'hello'
      @value = 'world!'

      @cloud.stub!(:locate_node_or_init).and_return(@generic_node)
    end

    after do
      @cloud.set(@key, @value)
    end

    it "should lookup the node or init for where to place key" do
      @cloud.should_receive(:locate_node_or_init).with(@key, anything).once.and_return(@generic_node)
    end

    it "should set the value on the node returned by locate node or init" do
      @generic_node.should_receive(:set).with(@key, @value)
    end
  end

  describe "getting" do
    before do
      @key = 'foo'
      @value = 'baz'
      @storage_ring.should_receive(:get_node).with(@key).and_return(@generic_node)
    end

    after do
      @cloud.get(@key).should eql(@value)
    end

    it "should not resort to the lookup table if it can find the key directly" do
      @generic_node.should_receive(:get).with(@key).and_return(@value)

      @cloud.should_not_receive(:locate_node)
    end

    it "should get the storage node from the lookup table if it can't find the key directly" do
      @generic_node.should_receive(:get).once.and_return(nil)

      @cloud.should_receive(:locate_node).with(@key, anything).and_return(@storage_valid_node)
      @storage_valid_node.should_receive(:get).with(@key).and_return(@value)
    end
  end

  describe "deleting" do
    before do
      @key = 'foo'
      @value = 'baz'
    end

    after do
      # I wrap this in a should_not raise error for the final
      # spec in this context, which WOULD raise an error if
      # it failed
      lambda do
        @cloud.delete(@key)
      end.should_not raise_error
    end

    it "should delete the key from first two lookup nodes from iteration" do
      @nodes[0].should_receive(:delete).with(@key).once
      @nodes[1].should_receive(:delete).with(@key).once
      @nodes[2].should_not_receive(:delete)
    end

    it "should first try to get the storage node from lookup ring" do
      @cloud.should_receive(:locate_node).with(@key, anything).once.and_return(@generic_node)
      @cloud.should_not_receive(:get_storage_ring)
    end

    it "should try to get storage node directly if lookup ring failed" do
      @cloud.should_receive(:locate_node).with(@key, anything).once.and_return(nil)
      @cloud.should_receive(:get_storage_ring).once.and_return(@storage_ring)
      @storage_ring.should_receive(:get_node).with(@key).once.and_return(@generic_node)

      @generic_node.should_receive(:delete).with(@key)
    end

    it "should only delete from a storage node if one was found" do
      @cloud.should_receive(:locate_node).with(@key, anything).once.and_return(nil)
      @cloud.should_receive(:get_storage_ring).once.and_return(@storage_ring)
      @storage_ring.should_receive(:get_node).with(@key).once.and_return(nil)
    end
  end

  describe "class methods" do
    before do
      LightCloud.should_receive(:instance).and_return(@cloud)
      
      @key = 'foo'
      @value = 'bar'
    end

    it "should call add_system on singleton when init is called" do
      @cloud.should_receive(:add_system).with(@valid_lookup_nodes, @valid_storage_nodes, anything)

      LightCloud.init(@valid_lookup_nodes, @valid_storage_nodes)
    end

    it "should call get on instance for get" do
      @cloud.should_receive(:get).with(@key, anything).once
      
      LightCloud.get(@key)
    end

    it "should call set on instance for set" do
      @cloud.should_receive(:set).with(@key, @value, anything).once

      LightCloud.set(@key, @value)
    end

    it "should call delete on instance for delete" do
      @cloud.should_receive(:delete).with(@key, anything).once

      LightCloud.delete(@key)
    end
  end
end
