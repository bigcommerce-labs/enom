require 'active_support'
require 'active_support/core_ext/object/blank'
require 'active_support/core_ext/date/calculations'
require "public_suffix"

module Enom

  class Domain
    include HTTParty
    include ContactInfo

    # The domain name on Enom
    attr_reader :name

    # Second-level and first-level domain on Enom
    attr_reader :sld, :tld

    # Domain expiration date (currently returns a string - 11/9/2010 11:57:39 AM)
    attr_reader :expiration_date

    def initialize(attributes)
      #
      # use __content__ to get domainname if needed
      # @see https://github.com/sferik/multi_xml/pull/27
      #
      @name = if attributes["domainname"]
                attributes["domainname"]["__content__"] || attributes["domainname"]
              else
                attributes["DomainName"]
              end

      @sld, @tld = Domain.parse_sld_and_tld(@name)

      expiration_date_string = attributes["expiration_date"] || attributes["status"]["expiration"]
      @expiration_date = Date.strptime(expiration_date_string.split(" ").first, "%m/%d/%Y")

      # If we have more attributes for the domain from running GetDomainInfo
      # (as opposed to GetAllDomains), we should save it to the instance to
      # save on future API calls
      if attributes["services"] && attributes["status"]
        set_extended_domain_attributes(attributes)
      end
    end

    # Find the domain (must be in your account) on Enom
    def self.find(name, tld = nil)
      if tld.present?
        sld = name
      else
        sld, tld = parse_sld_and_tld(name)
      end

      response = Client.request("Command" => "GetDomainInfo", "SLD" => sld, "TLD" => tld)["interface_response"]["GetDomainInfo"]
      Domain.new(response)
    end

    # Determine if the domain is available for purchase
    def self.check(name, tld = nil)
      available?(name, tld) ? "available" : "unavailable"
    end

    # Boolean helper method to determine if the domain is available for purchase
    def self.available?(name, tld = nil)
      if tld.present?
        sld = name
      else
        sld, tld = parse_sld_and_tld(name)
      end

      response = Client.request("Command" => "Check", "SLD" => sld, "TLD" => tld)["interface_response"]["RRPCode"]
      response == "210"
    end

    # Determine if a list of domains are available for purchase
    # Returns an array of available domain names given

    # Default TLD check lists
    # *   com, net, org, info, biz, us, ws, cc, tv, bz, nu
    # *1  com, net, org, info, biz, us, ws
    # *2  com, net, org, info, biz, us
    # @   com, net, org

    # You can provide one of the default check lists or provide an array of strings
    # to check a custom set of TLDs. Enom currently chokes when specifying a custom
    # list, so this will raise a NotImplementedError until Enom fixes this
    def self.check_multiple_tlds(sld, tlds = "*")
      if tlds.kind_of?(Array)
        # list = tlds.join(",")
        # tld  = nil
        raise NotImplementedError
      elsif %w(* *1 *2 @).include?(tlds)
        list = nil
        tld  = tlds
      end

      response = Client.request("Command" => "Check", "SLD" => sld, "TLD" => tld, "TLDList" => list)

      result = []
      response["interface_response"].each do |k, v|
        if v == "210" #&& k[0,6] == "RRPCode"
          pos = k[7..k.size]
          result << response["interface_response"]["Domain#{pos}"] unless k.nil? || k.empty?
        end
      end

      return result
    end

    # Find and return all domains in the account
    def self.all(options = {})
      response = Client.request("Command" => "GetAllDomains")["interface_response"]["GetAllDomains"]["DomainDetail"]

      domains = []
      response.each {|d| domains << Domain.new(d) }
      return domains
    end

    # Purchase the domain
    def self.register!(name, options = {})
      sld, tld = parse_sld_and_tld(name)
      opts = {}
      options = options.dup

      if options[:nameservers]
        count = 1
        options.delete(:nameservers).each do |nameserver|
          opts.merge!("NS#{count}" => nameserver)
          count += 1
        end
      else
        opts.merge!("UseDNS" => "default")
      end

      opts.merge!("NumYears" => options.delete(:years)) if options[:years]
      opts.merge!(options)

      response = Client.request({"Command" => "Purchase", "SLD" => sld, "TLD" => tld}.merge(opts))
      Domain.find(name)
    end

    # Delete a domain name registration from your account. The domain must be
    # less than 5 days old and you must be on Enom's "DeleteRegistration
    # whitelist" for resellers (your account rep can enable it for you).
    #
    # Returns true if successful, false if failed.
    def self.delete!(name, options = {})
      sld, tld = parse_sld_and_tld(name)

      response = Client.request({'Command' => 'DeleteRegistration', 'SLD' => sld, 'TLD' => tld}.merge(options))['interface_response']
      response['RRPCode'].to_i == 200
    end

    # Transfer domain from another registrar to Enom, charges the account when successful
    # Returns true if successful, false if failed
    def self.transfer!(name, auth, options = {})
      sld, tld = parse_sld_and_tld(name)

      # Default options
      opts = {
        "OrderType"   => "AutoVerification",
        "DomainCount" => 1,
        "SLD1"        => sld,
        "TLD1"        => tld,
        "AuthInfo1"   => auth, # Authorization (EPP) key from the
        "UseContacts" => 1     # Set UseContacts=1 to transfer existing Whois contacts with a domain that does not require extended attributes.
      }

      opts.merge!("Renew" => 1) if options[:renew]

      response = Client.request({"Command" => "TP_CreateOrder"}.merge(opts))["ErrCount"]

      response.to_i == 0
    end


    # Renew the domain
    def self.renew!(name, options = {})
      sld, tld = parse_sld_and_tld(name)
      opts = {}
      opts.merge!("NumYears" => options[:years]) if options[:years]
      renew_response = Client.request({"Command" => "Extend", "SLD" => sld, "TLD" => tld}.merge(opts))
      domain = Domain.find(name)
      # Enom doesn't make the new registration date immediately available in the find request, so we patch that
      # value into the object.
      registry_exp_date = renew_response.parsed_response['interface_response']['DomainInfo']['RegistryExpDate']
      domain.expiration_date = Date.strptime(registry_exp_date.split(" ").first, '%Y-%m-%d')
      domain
    end

    # Renew a domain that has already expired
    def self.update_expired!(name, years = 1)
      unless valid_renewal_length?(years)
        raise ArgumentError, "Renewal years must be an integer between 1 and 10!"
      end

      request_params = {
        "Command"    => "UpdateExpiredDomains",
        "DomainName" => name,
        "NumYears"   => years
      }

      response = Client.request(request_params)
      if response['interface_response']['ErrCount'] != "0"
        return false
      end

      domain = Domain.find(name)
      # Enom doesn't make the new registration date and status immediately available in the find request, so
      # we patch that value into the object if necessary.
      if (domain.expiration_date < Date.today)
        domain.expiration_date = domain.expiration_date.advance(years: years)
      end

      if (domain.registration_status == "Expired")
        domain.registration_status = "Registered"
      end

      domain
    end

    def self.valid_renewal_length?(years)
      years >= 1 && years <= 10
    end

    # Suggest available domains using the namespinner
    # Returns an array of available domain names that match
    def self.suggest(name, options ={})
      sld, tld = parse_sld_and_tld(name)
      opts = {}
      opts.merge!("MaxResults" => options[:max_results] || 8, "Similar" => options[:similar] || "High")
      response = Client.request({"Command" => "namespinner", "SLD" => sld, "TLD" => tld}.merge(opts))

      suggestions = []
      response["interface_response"]["namespin"]["domains"]["domain"].map do |d|
        (options[:tlds] || %w(com net tv cc)).each do |toplevel|
          suggestions << [d["name"].downcase, toplevel].join(".") if d[toplevel] == "y"
        end
      end
      return suggestions
    end

    # Parse out domain name tld and sld from the PublicSuffix lib
    def self.parse_sld_and_tld(domain_name)
      d = PublicSuffix.parse(domain_name)
      [d.sld, d.tld]
    end

    # Lock the domain at the registrar so it can"t be transferred
    def lock
      Client.request("Command" => "SetRegLock", "SLD" => sld, "TLD" => tld, "UnlockRegistrar" => "0")
      @locked = true
      return self
    end

    # Unlock the domain at the registrar to permit transfers
    def unlock
      Client.request("Command" => "SetRegLock", "SLD" => sld, "TLD" => tld, "UnlockRegistrar" => "1")
      @locked = false
      return self
    end

    ##
    # Get auto-renew state of Domain
    #
    # @return [Boolean]
    #
    def auto_renew?
      unless defined?(@auto_renew)
        # GetRenew call will fail if the domain is expired, so check first
        if expired?
          @auto_renew = false # Expired domains cannot be set to auto-renew
        else
          response = Client.request('Command' => 'GetRenew', 'SLD' => sld, 'TLD' => tld)
          validate_response!(response)
          @auto_renew = response['interface_response']['auto_renew'].to_i
        end
      end
      @auto_renew
    end
    alias_method :auto_renew, :auto_renew?

    ##
    # Set auto-renew state for the domain
    #
    # @param [Boolean|Integer] auto_renew
    # @return [Enom::Domain]
    #
    def auto_renew=(auto_renew)
      response = Client.request('Command' => 'SetRenew', 'SLD' => sld, 'TLD' => tld, 'RenewFlag' => auto_renew)
      validate_response!(response)
      @auto_renew = auto_renew == 1
      self
    end

    #
    # synchronize EPP key with Registry, and optionally email it to owner
    #
    def sync_auth_info(options = {})

      opts = {
        "RunSynchAutoInfo" => 'True',
        "EmailEPP" => 'True'
      }
      opts["EmailEPP"] = 'True' if options[:email]

      Client.request({"Command" => "SynchAuthInfo", "SLD" => sld, "TLD" => tld}.merge(opts))
      return self
    end


    # Check if the domain is currently locked.  locked? helper method also available
    def locked
      unless defined?(@locked)
        response = Client.request("Command" => "GetRegLock", "SLD" => sld, "TLD" => tld)["interface_response"]["reg_lock"]
        @locked = response == "1"
      end
      return @locked
    end
    alias_method :locked?, :locked

    # Check if the domain is currently unlocked.  unlocked? helper method also available
    def unlocked
      !locked?
    end
    alias_method :unlocked?, :unlocked

    # Return the DNS nameservers that are currently used for the domain
    def nameservers
      get_extended_domain_attributes unless @nameservers
      return @nameservers
    end

    def update_nameservers(nameservers = [])
      count = 1
      ns = {}
      if (2..12).include?(nameservers.size)
        nameservers.each do |nameserver|
          ns.merge!("NS#{count}" => nameserver)
          count += 1
        end
        Client.request({"Command" => "ModifyNS", "SLD" => sld, "TLD" => tld}.merge(ns))
        @nameservers = ns.values
        return self
      else
        raise InvalidNameServerCount
      end
    end

    def expiration_date
      unless defined?(@expiration_date)
        date_string = @domain_payload["interface_response"]["GetDomainInfo"]["status"]["expiration"]
        @expiration_date = Date.strptime(date_string.split(" ").first, "%m/%d/%Y")
      end
      @expiration_date
    end

    def expiration_date=(date)
      @expiration_date = date
    end

    def registration_status
      get_extended_domain_attributes unless @registration_status
      return @registration_status
    end

    def registration_status=(status)
      @registration_status = status
    end

    def active?
      registration_status == "Registered"
    end

    def expired?
      registration_status == "Expired"
    end

    def renew!(options = {})
      Domain.renew!(name, options)
    end

    private

    # Make another API call to get all domain info. Often necessary when domains are
    # found using Domain.all instead of Domain.find.
    def get_extended_domain_attributes
      sld, tld = name.split(".")
      attributes = Client.request("Command" => "GetDomainInfo", "SLD" => sld, "TLD" => tld)["interface_response"]["GetDomainInfo"]
      set_extended_domain_attributes(attributes)
    end

    # Set any more attributes that we have to work with to instance variables
    def set_extended_domain_attributes(attributes)
      @nameservers = attributes["services"]["entry"].first["configuration"]["dns"]
      @registration_status = attributes["status"]["registrationstatus"]
      return self
    end

    ##
    # Validate the response from Enom
    #
    # @raise [Enom::InterfaceError] If response is invalid
    def validate_response!(response)
      unless response.respond_to?(:key?) && response.key?('interface_response')
        raise Enom::InterfaceError, response.inspect
      end
    end
  end
end
