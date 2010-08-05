# -*- coding: utf-8 -*-
require 'savon'
require 'net/https'
require 'digest/md5'

# The idea is to create an object proxy to the web service client with the same structure 
# than the IControl stuff

module IControl

  class NotConfiguredException < Exception; end

  module Common
    class IPPortDefinition
      attr_accessor :address,:port
      def initialize(options)
        @address = options[:address]
        @port = options[:port]
      end
    end    
  end


  class Base

    def default_body
      { self.class.id_name.to_s + "s" =>  {:value => [@attributes[:id]] } }
    end

    # Generic type mapping
    def self.map_response(response)
      response_key = response.keys.first
      if response_key
        if response[response_key].has_key? :return
          return IControl::Mappings.map_object(response[response_key][:return]) 
        else
          return nil
        end
      else
        raise "Invalid Response #{response.inspect}"
      end
    end

    def self.find(name)
      return self.find_all if name == :all 
      if name == :first
        all = self.find_all
        return all[0] if all.length >0
      end
      if self.get_list.include?(name)
        return self.new(:id => name)
      else
        return nil
      end
    end

    def self.find_all
      self.get_list.map {|i| self.new(:id => i)}
    end    

    def method_missing(method_name,*args,&block)
      
       return super if @attributes.has_key? method_name 

      if self.class.wsdl.operations.keys.include?("get_#{method_name}".to_sym)
        return self.class.send("get_#{method_name}".to_sym) do |soap|
          soap.body = default_body
        end
      end

      if self.class.wsdl.operations.keys.include?("#{method_name}".to_sym)
        return self.class.send("#{method_name}".to_sym) do |soap|
          soap.body = default_body
        end
      end
      
      return super
    end

    include Attributable

  end

  class << self
    attr_accessor :config
  end
  
  def self.configured?
    return @config[:user] != "" && @config[:password] != "" && @config[:base_url] != ""
  end

  @config = {
    :user     => "",               # username and password
    :password => "",
    :base_url => "",                # base url for the web-service (https://example.com/iControl/iControlPortal.cgi)
    :test_mode => false,           # When test mode is set, the soap responses are saved (this is done to ease the testing fixtures generation)
    :test_path => File.join(File.dirname(__FILE__),"..","..","spec","fixtures")
  }

  def self.save_test_info(request,response,wsdl,class_name,method_name)
    
    request_md5 = Digest::MD5.hexdigest(request)
    request_file_name  = request_raw_file_name = File.join(IControl.config[:test_path],"soap","xml","#{class_name}.#{method_name}_#{request_md5}_request")
    response_file_name = response_raw_file_name = File.join(IControl.config[:test_path],"soap","xml","#{class_name}.#{method_name}_#{request_md5}_response")

    timestamp = Time.now.strftime("%Y%m%d%m%S") + Time.now.usec.to_s 

    while File.exists?(response_file_name + ".xml") || File.exists?(request_file_name + ".xml")
      response_file_name = response_raw_file_name + "." + timestamp
      request_file_name = request_raw_file_name + "." + timestamp
    end

    File.open(response_file_name + ".xml","w") { |file| file << response.to_xml }
    File.open(request_file_name + ".xml","w") { |file| file << request }
    
    wsdl_file_name = File.join(IControl.config[:test_path],"wsdl","xml","#{class_name}.xml")
    unless File.exists?(wsdl_file_name) 
      File.open(wsdl_file_name,"w") do |file|
        file << wsdl
      end
    end
  end



  def IControl.const_missing(name)
    
    # Whenever we find a new module subclassing IControl we create it
    
    modulo = Module.new do 

      # This new module has the ability to automatically create classes when subclassing from it

      (class << self; self; end).instance_eval do                 # We do it in the eigenclass
        
        define_method("const_missing") do |class_name|
          
          # Whenever we are called with a class name we create a new one based on the configuration we have
          
          klass = Class.new(IControl::Base) do

            (class << self; self; end).instance_eval do 
              
              define_method("client") do 
                return @client if @client
                @client = nil
                if IControl.configured?
                  @client = Savon::Client.new IControl.config[:base_url] + "?WSDL=#{name.to_s}.#{class_name.to_s}"
                  @client.request.basic_auth IControl.config[:user],IControl.config[:password]
                  @client.request.http.ssl_client_auth( :verify_mode => OpenSSL::SSL::VERIFY_NONE )
                else
                  raise IControl::NotConfiguredException
                end
                return @client
              end
              
              # This is done this way cause I need access to name and class_name
              # metaprogramming to cross the scope, don't really like it actually.
              # TODO: Make use of the delegation patern much more clean I think
                            
              define_method("method_missing") do |method_name,*args,&block|

                raise IControl::NotConfiguredException unless IControl.configured?
                if client 
                  if client.wsdl.operations.keys.include?(method_name)  
                    # When calling a soap method we transparently add the ns
                    request = ""
                    response = client.send(method_name,*args) do |soap|
                      soap.namespaces["xmlns:wsdl"] = "urn:iControl:#{name}/#{class_name}"
                      block.call(soap) if block
                      request = soap.to_xml
                    end
                    # In case we save test fixtures
                    IControl.save_test_info(request,response, client.wsdl ,"IControl.#{name}.#{class_name}",method_name) if IControl.config[:test]
                    return self.map_response(response.to_hash)
                  else
                    client.send(method_name,*args,&block)
                  end
                else
                  super(method_name,*args,&block)
                end 
              end
            end
          end
          self.const_set(class_name,klass)
        end
      end
    end
    self.const_set(name,modulo)
  end
end

# If we are going to redefine any give class we need to force the const_missing for the 
# initial declaration to be made


