require 'test_dummy/railtie'

module TestDummy
  def self.included(base)
    base.send(:extend, ClassMethods)
    base.send(:include, InstanceMethods)
  end
  
  # Combines several sets of parameters together into a single set in order
  # of lowest priority to highest priority. Supplied list can contain nil
  # values which will be ignored. Returns a Hash with symbolized keys.
  def self.combine_attributes(*sets)
    combined_attributes = { }
    
    # Apply sets in order they are listed
    sets.compact.each do |set|
      set.each do |k, v|
        case (v)
        when nil
          # Ignore nil assignments
        else
          combined_attributes[k.to_sym] = v
        end
      end
    end

    combined_attributes
  end

  # Adds a mixin to the core DummyMethods module
  def self.add_module(new_module)
    DummyMethods.send(:extend, new_module)
  end
  
  # Used in an initializer to define things that can be dummyd by all
  # models if these properties are available.
  def self.can_dummy(*names, &block)
    case (names.last)
    when Hash
      options = names.pop
    end
    
    if (options and options[:with])
      block = options[:with]
    end

    DummyMethods.send(
      :extend,
      names.inject(Module.new) do |m, name|
        m.send(:define_method, name, &block)
        m
      end
    )
  end
  
  # Used in an initializer to define configuration parameters.
  def self.config(&block)
    TestDummy.instance_eval(&block)
  end
  
  module DummyMethods
    # Container for common data faking methods as they are defined.
  end
  
  module ClassMethods
    # Returns a Hash which describes the dummy configuration for this
    # Model class.
    def dummy_attributes
      @test_dummy ||= { }
    end
    
    # Declares how to fake one or more attributes. Accepts a block
    # that can receive up to two parameters, the first the instance of
    # the model being created, the second the parameters supplied to create
    # it. The first and second parameters may be nil.
    def can_dummy(*names, &block)
      options = nil

      case (names.last)
      when Hash
        options = names.pop
      end
      
      if (options and options[:with])
        block = options[:with]
      end
      
      @test_dummy ||= { }
      @test_dummy_order ||= [ ]
      
      names.flatten.each do |name|
        name = name.to_sym

        # For associations, delay creation of block until first call
        # to allow for additional relationships to be defined after
        # the can_dummy call. Leave placeholder (true) instead.

        @test_dummy[name] = block || true
        @test_dummy_order << name
      end
    end
    
    # Returns true if all the supplied attribute names have defined
    # dummy methods, or false otherwise.
    def can_dummy?(*names)
      @test_dummy ||= { }
      
      names.flatten.reject do |name|
        @test_dummy.key?(name)
      end.empty?
    end
    
    # Builds a dummy model with some parameters set as supplied. The
    # new model is provided to the optional block for manipulation before
    # the dummy operation is completed. Returns a dummy model which has not
    # been saved.
    def build_dummy(with_attributes = nil)
      model = new(self.class.combine_attributes(scope(:create), with_attributes))

      yield(model) if (block_given?)

      self.execute_dummy_operation(model, with_attributes)
      
      model
    end
    
    # Builds a dummy model with some parameters set as supplied. The
    # new model is provided to the optional block for manipulation before
    # the dummy operation is completed and the model is saved. Returns a
    # dummy model. The model may not have been saved if there was a
    # validation failure, or if it was blocked by a callback.
    def create_dummy(with_attributes = nil, &block)
      model = build_dummy(with_attributes, &block)
      
      model.save
      
      model
    end

    # Builds a dummy model with some parameters set as supplied. The
    # new model is provided to the optional block for manipulation before
    # the dummy operation is completed and the model is saved. Returns a
    # dummy model. Will throw ActiveRecord::RecordInvalid if there was a
    # validation failure, or ActiveRecord::RecordNotSaved if the save was
    # blocked by a callback.
    def create_dummy!(with_attributes = nil, &block)
      model = build_dummy(with_attributes, &block)
      
      model.save!
      
      model
    end
    
    # Produces dummy data for a single attribute.
    def dummy(name, with_attributes = nil)
      with_attributes = TestDummy.combine_attributes(scope(:create), with_attributes)
      
      dummy_method_call(nil, with_attributes, dummy_method(name))
    end
    
    # Produces a complete set of dummy attributes. These can be used to
    # create a model.
    def dummy_attributes(with_attributes = nil)
      with_attributes = TestDummy.combine_attributes(scope(:create), with_attributes)
      
      @test_dummy_order.each do |field|
        unless (with_attributes.key?(field))
          result = dummy(field, with_attributes)
          
          case (result)
          when nil, with_attributes
            # Declined to populate parameters if method returns nil
            # or returns the existing parameter set.
          else
            with_attributes[field] = result
          end
        end
      end
      
      with_attributes
    end
    
    # This performs the dummy operation on a model with an optional set
    # of parameters.
    def execute_dummy_operation(model, with_attributes = nil)
      @test_dummy_order.each do |name|
        if (reflection = reflect_on_association(name))
          unless ((with_attributes and with_attributes.key?(name.to_sym)) or model.send(name))
            model.send(:"#{name}=", dummy_method_call(model, with_attributes, dummy_method(name)))
          end
        else
          unless (with_attributes and (with_attributes.key?(name.to_sym) or with_attributes.key?(name.to_s)))
            model.send(:"#{name}=", dummy_method_call(model, with_attributes, dummy_method(name)))
          end
        end
      end
      
      model
    end
    
  protected
    def dummy_method_call(model, with_attributes, block)
      case (block.arity)
      when 2, -1
        block.call(model, with_attributes)
      when 1
        block.call(model)
      else
        block.call
      end
    end
    
    def dummy_method(name)
      name = name.to_sym
      
      block = @test_dummy[name]

      case (block)
      when Module
        block.method(name)
      when Symbol
        DummyMethods.method(name)
      when true
        # Configure association dummyr the first time it is called
        if (reflection = reflect_on_association(name))
          primary_key = reflection.primary_key_name.to_sym

          @test_dummy[name] =
            lambda do |model, with_attributes|
              (with_attributes and with_attributes.key?(primary_key)) ? nil : reflection.klass.send(:create_dummy)
            end
        else
          raise "Cannot dummy unknown relationship #{name}"
        end
      else
        block
      end
    end
  end
  
  module InstanceMethods
    # Assigns any attributes which can be dummied that have not already
    # been populated.
    def dummy!(with_attributes = nil)
      self.class.execute_dummy_operation(self, with_attributes)
    end
  end
end
