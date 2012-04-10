# encoding: utf-8

=begin
    Copyright 2010-2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'rubygems'
require 'bundler/setup'

require 'ap'
require 'pp'

require File.expand_path( File.dirname( __FILE__ ) ) + '/options'
opts = Arachni::Options.instance

require opts.dir['lib'] + 'version'
require opts.dir['lib'] + 'ruby'
require opts.dir['lib'] + 'exceptions'
require opts.dir['lib'] + 'spider'
require opts.dir['lib'] + 'parser'
require opts.dir['lib'] + 'issue'
require opts.dir['lib'] + 'module'
require opts.dir['lib'] + 'plugin'
require opts.dir['lib'] + 'audit_store'
require opts.dir['lib'] + 'http'
require opts.dir['lib'] + 'report'
require opts.dir['lib'] + 'database'
require opts.dir['lib'] + 'component_manager'
require opts.dir['mixins'] + 'progress_bar'


module Arachni

#
# The Framework class ties together all the components.
#
# It should be wrapped by a UI class.
#
# It's the brains of the operation, it bosses the rest of the classes around.
#
# It runs the audit, loads modules and reports and runs them according to
# user options.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Framework

    #
    # include the output interface but try to use it as little as possible
    #
    # the UI classes should take care of communicating with the user
    #
    include Arachni::UI::Output

    include Arachni::Module::Utilities
    include Arachni::Mixins::Observable

    # the version of *this* class
    REVISION     = '0.2.6'

    #
    # Instance options
    #
    # @return [Options]
    #
    attr_reader :opts

    #
    # @return   [Arachni::Report::Manager]   report manager
    #
    attr_reader :reports

    #
    # @return   [Arachni::Module::Manager]   module manager
    #
    attr_reader :modules

    #
    # @return   [Arachni::Plugin::Manager]   plugin manager
    #
    attr_reader :plugins

    #
    # @return   [Arachni::Spider]   spider
    #
    attr_reader :spider

    #
    # URLs of all discovered pages
    #
    # @return   [Array]
    #
    attr_reader :sitemap

    #
    # Array of URLs that have been audited
    #
    # @return   [Array]
    #
    attr_reader :auditmap

    #
    # Total number of pages added to their audit queue
    #
    # @return   [Integer]
    #
    attr_reader :page_queue_total_size

    #
    # Total number of urls added to their audit queue
    #
    # @return   [Integer]
    #
    attr_reader :url_queue_total_size

    #
    # Initializes system components.
    #
    # @param    [Options]    opts
    #
    def initialize( opts )

        Encoding.default_external = "BINARY"
        Encoding.default_internal = "BINARY"

        @opts = opts

        if @opts.cookie_string
            @opts.cookies ||= []
            @opts.cookies |= @opts.cookie_string.split( ';' ).map {
                |cookie_pair|
                k, v = *cookie_pair.split( '=', 2 )
                Arachni::Parser::Element::Cookie.new( @opts.url.to_s, k => v )
            }.flatten.compact
        end

        @modules = Arachni::Module::Manager.new( @opts )
        @reports = Arachni::Report::Manager.new( @opts )
        @plugins = Arachni::Plugin::Manager.new( self )

        # will store full-fledged pages generated by the Trainer since these
        # may not be be accessible simply by their URL
        # @page_queue = ::Arachni::Database::Queue.new
        @page_queue = Queue.new
        @page_queue_total_size = 0

        # will hold paths found by the spider in order to be converted to pages
        # and ultimately audited by the modules
        @url_queue = Queue.new
        @url_queue_total_size = 0

        prepare_cookie_jar!
        prepare_user_agent!

        # deep clone the redundancy rules to preserve their counter
        # for the reports
        @orig_redundant = @opts.redundant.deep_clone

        @running = false
        @status = :ready
        @paused  = []

        @store = nil

        @auditmap = []
        @sitemap  = []

        @current_url = ''
    end

    #
    # @return   [Arachni::HTTP]     HTTP instance
    #
    def http
        Arachni::HTTP.instance
    end

    #
    # Prepares the framework for the audit.
    #
    # Sets the status to 'running', starts the clock and runs the plugins.
    #
    # Must be called just before calling {#audit}.
    #
    def prepare
        @running = true
        @opts.start_datetime = Time.now

        # run all plugins
        @plugins.run
    end

    #
    # Runs the system
    #
    # It parses the instance options, {#prepare}, runs the {#audit} and {#clean_up!}.
    #
    # @param   [Block]     &block  a block to call after the audit has finished
    #                                   but before running the reports
    #
    def run( &block )
        prepare

        # catch exceptions so that if something breaks down or the user opted to
        # exit the reports will still run with whatever results Arachni managed to gather
        exception_jail( false ){ audit }

        clean_up!
        exception_jail( false ){ block.call } if block_given?
        @status = :done

        if @opts.cookies
            # convert cookies to hashes for easier manipulation by the reports
            @opts.cookies = @opts.cookies.inject( {} ){ |h, c| h.merge!( c.simple ) }
        else
            @opts.cookies = {}
        end

        # run reports
        if @opts.reports && !@opts.reports.empty?
            exception_jail{ @reports.run( audit_store( ) ) }
        end

        true
    end

    #
    # Returns the status of the instance as a string.
    #
    # Possible values are (in order):
    # * ready -- Just initialised and waiting for instructions
    # * crawling -- The instance is crawling the target webapp
    # * auditing-- The instance is currently auditing the webapp
    # * paused -- The instance has posed (if applicable)
    # * cleanup -- The scan has completed and the instance is cleaning up
    #   after itself (i.e. waiting for plugins to finish etc.).
    # * done -- The scan has completed
    #
    # @return   [String]
    #
    def status
        return 'paused' if paused?
        @status.to_s
    end

    #
    # Returns the following framework stats:
    #
    # *  :requests         -- HTTP request count
    # *  :responses        -- HTTP response count
    # *  :time_out_count   -- Amount of timed-out requests
    # *  :time             -- Amount of running time
    # *  :avg              -- Average requests per second
    # *  :sitemap_size     -- Number of discovered pages
    # *  :auditmap_size    -- Number of audited pages
    # *  :progress         -- Progress percentage
    # *  :curr_res_time    -- Average response time for the current burst of requests
    # *  :curr_res_cnt     -- Amount of responses for the current burst
    # *  :curr_avg         -- Average requests per second for the current burst
    # *  :average_res_time -- Average response time
    # *  :max_concurrency  -- Current maximum concurrency of HTTP requests
    # *  :current_page     -- URL of the currently audited page
    # *  :eta              -- Estimated time of arrival i.e. estimated remaining time
    #
    # @param    [Bool]  refresh_time    updates the running time of the audit
    #                                       (usefully when you want stats while paused without messing with the clocks)
    #
    # @param    [Bool]  override_refresh
    #
    # @return   [Hash]
    #
    def stats( refresh_time = false, override_refresh = false )
        req_cnt = http.request_count
        res_cnt = http.response_count

        @opts.start_datetime = Time.now if !@opts.start_datetime

        sitemap_sz  = @url_queue_total_size + @page_queue_total_size
        auditmap_sz = @auditmap.size

        if( !refresh_time || auditmap_sz == sitemap_sz ) && !override_refresh
            @opts.delta_time ||= Time.now - @opts.start_datetime
        else
            @opts.delta_time = Time.now - @opts.start_datetime
        end

        avg = 0
        if res_cnt > 0
            avg = ( res_cnt / @opts.delta_time ).to_i
        end

        # we need to remove URLs that lead to redirects from the sitemap
        # when calculating the progress %.
        #
        # this is because even though these URLs are valid webapp paths
        # they are not actual pages and thus can't be audited;
        # so the sitemap and auditmap will never match and the progress will
        # never get to 100% which may confuse users.
        #
        if @spider
            redir_sz = @spider.redirects.size
        else
            redir_sz = 0
        end

        #
        # There are 2 audit phases:
        #  * regular analysis attacks
        #  * timing attacks
        #
        # When calculating the progress % we have to take both into account,
        # however each is calculated using different criteria.
        #
        # Progress of regular attacks is calculated as:
        #     amount of audited pages / amount of all discovered pages
        #
        # However, the progress of the timing attacks is calculated as:
        #     amount of called timeout blocks / amount of total blocks
        #
        # The timing attack modules are run with the regular ones however
        # their procedures are piled up into an array of Procs
        # which are called after the regular attacks.
        #
        # So when we reach the point of needing to include their progress in
        # the overall progress percentage we'll be working with accurate
        # data regarding the total blocks, etc.
        #

        #
        # If we have timing attacks then each phase must account for half
        # of the progress.
        #
        # This is not very granular but it's good enough for now...
        #
        if Arachni::Module::Auditor.timeout_loaded_modules.size > 0
            multi = 50
        else
            multi = 100
        end

        progress = (Float( auditmap_sz ) /
            ( sitemap_sz - redir_sz ) ) * multi

        if Arachni::Module::Auditor.running_timeout_attacks?

            called_blocks = Arachni::Module::Auditor.timeout_audit_operations_cnt -
                Arachni::Module::Auditor.current_timeout_audit_operations_cnt

            progress += ( Float( called_blocks ) /
                Arachni::Module::Auditor.timeout_audit_operations_cnt ) * multi
        end

        begin
            progress = Float( sprintf( "%.2f", progress ) )
        rescue
            progress = 0.0
        end

        # sometimes progress may slightly exceed 100%
        # which can cause a few strange stuff to happen
        progress = 100.0 if progress > 100.0

        {
            :requests   => req_cnt,
            :responses  => res_cnt,
            :time_out_count  => http.time_out_count,
            :time       => audit_store.delta_time,
            :avg        => avg,
            :sitemap_size  => @sitemap.size,
            :auditmap_size => auditmap_sz,
            :progress      => progress,
            :curr_res_time => http.curr_res_time,
            :curr_res_cnt  => http.curr_res_cnt,
            :curr_avg      => http.curr_res_per_second,
            :average_res_time => http.average_res_time,
            :max_concurrency  => http.max_concurrency,
            :current_page     => @current_url,
            :eta           => ::Arachni::Mixins::ProgressBar.eta( progress, @opts.start_datetime )
        }
    end

    #
    # Pushes a page to the page audit queue and updates {#page_queue_total_size}
    #
    def push_to_page_queue( page )
        @page_queue << page
        @page_queue_total_size += 1
    end

    #
    # Pushes a URL to the URL audit queue and updates {#url_queue_total_size}
    #
    def push_to_url_queue( url )
        @url_queue << url
        @url_queue_total_size += 1
    end

    #
    # Performs the audit
    #
    # Runs the spider, pushes each page or url to their respective audit queue,
    # calls {#audit_queue}, runs the timeout attacks ({Arachni::Module::Auditor.timeout_audit_run}) and finally re-runs
    # {#audit_queue} in case the timing attacks uncovered a new page.
    #
    def audit
        wait_if_paused

        @status = :crawling
        @spider = Arachni::Spider.new( @opts )

        # if we're restricted to a given list of paths there's no reason to run the spider
        if @opts.restrict_paths && !@opts.restrict_paths.empty?

            @sitemap = @opts.restrict_paths
            @sitemap.each {
                |url|
                push_to_url_queue( url_sanitize( to_absolute( url ) ) )
            }
        else
            # initiates the crawl
            @spider.run( false ) {
                |response|
                @sitemap |= @spider.sitemap
                push_to_url_queue( url_sanitize( response.effective_url ) )
            }
        end

        @status = :auditing
        audit_queue

        exception_jail {
            if !Arachni::Module::Auditor.timeout_audit_blocks.empty?
                print_line
                print_status( 'Running timing attacks.' )
                print_info( '---------------------------------------' )
                Arachni::Module::Auditor.on_timing_attacks {
                    |_, elem|
                    @current_url = elem.action if !elem.action.empty?
                }
                Arachni::Module::Auditor.timeout_audit_run
            end

            audit_queue
        }
    end

    #
    # Audits the URL and Page queues
    #
    def audit_queue

        # goes through the URLs discovered by the spider, repeats the request
        # and parses the responses into page objects
        #
        # yes...repeating the request is wasteful but we can't store the
        # responses of the spider to consume them here because there's no way
        # of knowing how big the site will be.
        #
        while !@url_queue.empty? && url = @url_queue.pop

            http.get( url, :remove_id => true ).on_complete {
                |res|

                page = Arachni::Parser::Page.from_http_response( res, @opts )

                # audit the page
                exception_jail{ run_mods( page ) }

                # don't let the page queue build up,
                # consume it as soon as possible because the pages are stored
                # in the FS and thus take up precious system resources
                audit_page_queue
            }

            harvest_http_responses! if !@opts.http_harvest_last
        end

        harvest_http_responses! if( @opts.http_harvest_last )

        audit_page_queue

        harvest_http_responses! if( @opts.http_harvest_last )
    end

    #
    # Audits the page queue
    #
    def audit_page_queue
        # this will run until no new elements appear for the given page
        while !@page_queue.empty? && page = @page_queue.pop

            # audit the page
            exception_jail{ run_mods( page ) }
            harvest_http_responses! if !@opts.http_harvest_last
        end
    end


    #
    # Returns the results of the audit as an {AuditStore} instance
    #
    # @see AuditStore
    #
    # @return    [AuditStore]
    #
    def audit_store( fresh = true )

        # restore the original redundancy rules and their counters
        @opts.redundant = @orig_redundant
        opts = @opts.to_h
        opts['mods'] = @modules.keys

        if !fresh && @store
            @store
        else
            @store = AuditStore.new(
                version:  version,
                revision: revision,
                options:  opts,
                sitemap:  auditstore_sitemap || [],
                issues:   @modules.results.deep_clone,
                plugins:  @plugins.results
            )
         end
    end
    alias :auditstore :audit_store

    #
    # Returns an array of hashes with information
    # about all available modules
    #
    # @return    [Array<Hash>]
    #
    def lsmod
        @modules.available.map {
            |name|

            path = @modules.name_to_path( name )
            next if !lsmod_match?( path )

            @modules[name].info.merge(
                :mod_name => name,
                :author   => [@modules[name].info[:author]].flatten.map { |a| a.strip },
                :path     => path.strip
            )
        }.compact
    ensure
        @modules.clear
    end

    #
    # Returns an array of hashes with information
    # about all available reports
    #
    # @return    [Array<Hash>]
    #
    def lsrep
        @reports.available.map {
            |report|

            path = @reports.name_to_path( report )
            next if !lsrep_match?( path )

            @reports[report].info.merge(
                :rep_name => report,
                :path     => path,
                :author   => [@reports[report].info[:author]].flatten.map { |a| a.strip }
            )
        }.compact
    ensure
        @reports.clear
    end

    #
    # Returns an array of hashes with information
    # about all available reports
    #
    # @return    [Array<Hash>]
    #
    def lsplug
        @plugins.available.map {
            |plugin|

            path = @plugins.name_to_path( plugin )
            next if !lsplug_match?( path )

            @plugins[plugin].info.merge(
                :plug_name => plugin,
                :path      => path,
                :author    => [@plugins[plugin].info[:author]].flatten.map { |a| a.strip }
            )
        }.compact
    ensure
        @plugins.clear
    end

    #
    # @return   [Bool]  true if the framework is running
    #
    def running?
        @running
    end

    #
    # @return   [Bool]  true if the framework is paused or in the process of
    #
    def paused?
        !@paused.empty?
    end

    #
    # @return   [True]  pauses the framework on a best effort basis,
    #                       might take a while to take effect
    #
    def pause!
        @spider.pause! if @spider
        @paused << caller
        true
    end

    #
    # @return   [True]  resumes the scan/audit
    #
    def resume!
        @paused.delete( caller )
        @spider.resume! if @spider
        true
    end

    #
    # Returns the version of the framework
    #
    # @return    [String]
    #
    def version
        Arachni::VERSION
    end

    #
    # Returns the revision of the {Framework} (this) class
    #
    # @return    [String]
    #
    def revision
        REVISION
    end

    #
    # Cleans up the framework; should be called after running the audit or
    # after canceling a running scan.
    #
    # It stops the clock, waits for the plugins to finish up, register
    # their results and also refreshes the auditstore.
    #
    # It also runs {#audit_queue} in case any new pages have been added by the plugins.
    #
    # @param    [Bool]      skip_audit_queue    skips running {#audit_queue},
    #                                               set to true if you don't want any delays.
    #
    # @return   [True]
    #
    def clean_up!( skip_audit_queue = false )
        @status = :cleanup

        @opts.finish_datetime = Time.now
        @opts.delta_time = @opts.finish_datetime - @opts.start_datetime

        # make sure this is disabled or it'll break report output
        disable_only_positives!

        @running = false

        # wait for the plugins to finish
        @plugins.block!

        # a plug-in may have updated the page queue, rock it!
        audit_queue if !skip_audit_queue

        # refresh the audit store
        audit_store( true )

        true
    end

    private

    #
    # Special sitemap for the {#auditstore}.
    #
    # Used only under special circumstances, will usually return the {#sitemap}
    # but can be overridden by the {::Arachni::RPC::Framework}.
    #
    # @return   [Array]
    #
    def auditstore_sitemap
        @sitemap
    end

    def caller
        if /^(.+?):(\d+)(?::in `(.*)')?/ =~ ::Kernel.caller[1]
            Regexp.last_match[1]
        end
    end

    def wait_if_paused
        ::IO::select( nil, nil, nil, 1 ) while paused?
    end

    #
    # Prepares the user agent to be used throughout the system.
    #
    def prepare_user_agent!
        @opts.user_agent = 'Arachni/' + version if !@opts.user_agent

        return if !@opts.authed_by
        @opts.user_agent += " (Scan authorized by: #{@opts.authed_by})"
    end

    def prepare_cookie_jar!(  )
        return if !@opts.cookie_jar || !@opts.cookie_jar.is_a?( String )

        # make sure that the provided cookie-jar file exists
        if !File.exist?( @opts.cookie_jar )
            raise( Arachni::Exceptions::NoCookieJar,
                'Cookie-jar \'' + @opts.cookie_jar + '\' doesn\'t exist.' )
        end
    end


    #
    # Takes care of page audit and module execution
    #
    # It will audit one page at a time as discovered by the spider <br/>
    # and recursively check for new elements that may have <br/>
    # appeared during the audit.
    #
    # When no new elements appear the recursion will stop and a new page<br/>
    # will be accepted.
    #
    # @see Page
    #
    # @param    [Page]    page
    #
    def run_mods( page )
        return if !page

        print_line
        print_status( "Auditing: [HTTP: #{page.code}] " + page.url )


        call_on_run_mods( page.deep_clone )

        @current_url = page.url.to_s

        @modules.values.each {
            |mod|
            wait_if_paused
            run_mod( mod, page.deep_clone )
        }

        @auditmap << page.url
        @sitemap |= @auditmap
        @sitemap.uniq!


        harvest_http_responses! if !@opts.http_harvest_last
    end

    def harvest_http_responses!
        print_status( 'Harvesting HTTP responses...' )
        print_info( 'Depending on server responsiveness and network' +
            ' conditions this may take a while.' )

        # grab updated pages
        http.trainer.flush_pages.each { |page| push_to_page_queue( page ) }

        # run all the queued HTTP requests and harvest the responses
        http.run

        http.trainer.flush_pages.each { |page| push_to_page_queue( page ) }
    end
    alias :harvest_http_responses :harvest_http_responses!

    #
    # Passes a page to the module and runs it.<br/>
    # It also handles any exceptions thrown by the module at runtime.
    #
    # @see Page
    #
    # @param    [Class]   mod      the module to run
    # @param    [Page]    page
    #
    def run_mod( mod, page )
        return if !run_mod?( mod, page )

        begin
            @modules.run_one( mod, page, self )
        rescue SystemExit
            raise
        rescue Exception => e
            print_error( 'Error in ' + mod.to_s + ': ' + e.to_s )
            print_error_backtrace( e )
        end
    end

    #
    # Determines whether or not to run the module against the given page
    # depending on which elements exist in the page, which elements the module
    # is configured to audit and user options.
    #
    # @param    [Class]   mod      the module to run
    # @param    [Page]    page
    #
    # @return   [Bool]
    #
    def run_mod?( mod, page )
        return true if( !mod.info[:elements] || mod.info[:elements].empty? )

        elems = {
            Issue::Element::LINK => page.links && page.links.size > 0 && @opts.audit_links,
            Issue::Element::FORM => page.forms && page.forms.size > 0 && @opts.audit_forms,
            Issue::Element::COOKIE => page.cookies && page.cookies.size > 0 && @opts.audit_cookies,
            Issue::Element::HEADER => page.headers && page.headers.size > 0 && @opts.audit_headers,
            Issue::Element::BODY   => true,
            Issue::Element::PATH   => true,
            Issue::Element::SERVER => true,
        }

        elems.each_pair {
            |elem, expr|
            return true if mod.info[:elements].include?( elem ) && expr
        }

        false
    end

    def lsrep_match?( path )
        regexp_array_match( @opts.lsrep, path )
    end

    def lsmod_match?( path )
        regexp_array_match( @opts.lsmod, path )
    end

    def lsplug_match?( path )
        regexp_array_match( @opts.lsplug, path )
    end

    def regexp_array_match( regexps, str )
        cnt = 0
        regexps.each {
            |filter|
            cnt += 1 if str =~ filter
        }
        true if cnt == regexps.size
    end

end
end
