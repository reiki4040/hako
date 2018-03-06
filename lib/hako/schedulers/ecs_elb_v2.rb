# frozen_string_literal: true

require 'aws-sdk-elasticloadbalancingv2'
require 'hako'
require 'hako/error'

module Hako
  module Schedulers
    class EcsElbV2
      # @param [String] app_id
      # @param [String] region
      # @param [Hash] elb_v2_config
      # @param [Boolean] dry_run
      def initialize(app_id, region, elb_v2_config, dry_run:)
        @app_id = app_id
        @region = region
        @elb_v2_config = elb_v2_config
        @dry_run = dry_run
      end

      # @param [Aws::ECS::Types::LoadBalancer] ecs_lb
      # @return [nil]
      def show_status(ecs_lb)
        lb = describe_load_balancer
        elb_client.describe_listeners(load_balancer_arn: lb.load_balancer_arn).each do |page|
          page.listeners.each do |listener|
            puts "  #{lb.dns_name}:#{listener.port} -> #{ecs_lb.container_name}:#{ecs_lb.container_port}"
          end
        end
      end

      # @return [Aws::ElasticLoadBalancingV2::Types::LoadBalancer]
      def describe_load_balancer
        elb_client.describe_load_balancers(names: [@elb_v2_config.fetch('elb_name', name)]).load_balancers[0]
      rescue Aws::ElasticLoadBalancingV2::Errors::LoadBalancerNotFound
        nil
      end

      # @return [Aws::ElasticLoadBalancingV2::Types::TargetGroup]
      def describe_target_group
        elb_client.describe_target_groups(names: [name]).target_groups[0]
      rescue Aws::ElasticLoadBalancingV2::Errors::TargetGroupNotFound
        nil
      end

      # @param [Fixnum] front_port
      # @return [nil]
      def find_or_create_load_balancer(_front_port)
        unless @elb_v2_config
          return false
        end

        load_balancer = describe_load_balancer
        unless load_balancer
          tags = @elb_v2_config.fetch('tags', {}).map { |k, v| { key: k, value: v.to_s } }
          load_balancer = elb_client.create_load_balancer(
            name: @elb_v2_config.fetch('elb_name', name),
            subnets: @elb_v2_config.fetch('subnets'),
            security_groups: @elb_v2_config.fetch('security_groups'),
            scheme: @elb_v2_config.fetch('scheme', nil),
            tags: tags.empty? ? nil : tags,
          ).load_balancers[0]
          Hako.logger.info "Created ELBv2 #{load_balancer.dns_name}"
        end

        target_group = describe_target_group
        unless target_group
          target_group = elb_client.create_target_group(
            name: name,
            port: 80,
            protocol: 'HTTP',
            vpc_id: @elb_v2_config.fetch('vpc_id'),
            health_check_path: @elb_v2_config.fetch('health_check_path', nil),
            target_type: @elb_v2_config.fetch('target_type', nil),
          ).target_groups[0]
          Hako.logger.info "Created target group #{target_group.target_group_arn}"
        end

        listener_ports = elb_client.describe_listeners(load_balancer_arn: load_balancer.load_balancer_arn).flat_map { |page| page.listeners.map(&:port) }
        @elb_v2_config.fetch('listeners').each do |l|
          params = {
            load_balancer_arn: load_balancer.load_balancer_arn,
            protocol: l.fetch('protocol'),
            port: l.fetch('port'),
            default_actions: [{ type: 'forward', target_group_arn: target_group.target_group_arn }],
          }
          certificate_arn = l.fetch('certificate_arn', nil)
          if certificate_arn
            params[:certificates] = [{ certificate_arn: certificate_arn }]
          end

          unless listener_ports.include?(params[:port])
            listener = elb_client.create_listener(params).listeners[0]
            Hako.logger.info("Created listener #{listener.listener_arn}")
          end
        end

        true
      end

      # @return [nil]
      def modify_attributes
        unless @elb_v2_config
          return nil
        end

        if @elb_v2_config.key?('load_balancer_attributes')
          load_balancer = describe_load_balancer
          attributes = @elb_v2_config.fetch('load_balancer_attributes').map { |key, value| { key: key, value: value } }
          if @dry_run
            if load_balancer
              Hako.logger.info("elb_client.modify_load_balancer_attributes(load_balancer_arn: #{load_balancer.load_balancer_arn}, attributes: #{attributes.inspect}) (dry-run)")
            else
              Hako.logger.info("elb_client.modify_load_balancer_attributes(load_balancer_arn: unknown, attributes: #{attributes.inspect}) (dry-run)")
            end
          else
            Hako.logger.info("Updating ELBv2 attributes to #{attributes.inspect}")
            elb_client.modify_load_balancer_attributes(load_balancer_arn: load_balancer.load_balancer_arn, attributes: attributes)
          end
        end
        if @elb_v2_config.key?('target_group_attributes')
          target_group = describe_target_group
          attributes = @elb_v2_config.fetch('target_group_attributes').map { |key, value| { key: key, value: value } }
          if @dry_run
            if target_group
              Hako.logger.info("elb_client.modify_target_group_attributes(target_group_arn: #{target_group.target_group_arn}, attributes: #{attributes.inspect}) (dry-run)")
            else
              Hako.logger.info("elb_client.modify_target_group_attributes(target_group_arn: unknown, attributes: #{attributes.inspect}) (dry-run)")
            end
          else
            Hako.logger.info("Updating target group attributes to #{attributes.inspect}")
            elb_client.modify_target_group_attributes(target_group_arn: target_group.target_group_arn, attributes: attributes)
          end
        end
        nil
      end

      # @return [nil]
      def destroy
        unless @elb_v2_config
          return false
        end

        load_balancer = describe_load_balancer
        if load_balancer
          lb = describe_load_balancer
          listeners = elb_client.describe_listeners(load_balancer_arn: lb.load_balancer_arn).listeners

          config_listeners = @elb_v2_config.fetch('listeners')
          dryrun_deleted_listener_count = 0
          if listeners.length != config_listeners.length
            listeners.each do |l|
              config_listeners.each do |cl|
                if  l.port == cl.fetch('port')
                  if @dry_run
                    Hako.logger.info("elb_client.delete_listener(listener_arn: #{l.listener_arn})")
                    dryrun_deleted_listener_count += 1
                  else
                    elb_client.delete_listener(listener_arn: l.listener_arn)
                    Hako.logger.info "Deleted port #{l.port} Listener #{l.listener_arn}"
                  end
                end
              end
            end

            updated_listeners = elb_client.describe_listeners(load_balancer_arn: lb.load_balancer_arn)
            if (updated_listeners.listeners.length - dryrun_deleted_listener_count) == 0
              if @dry_run
              Hako.logger.info("elb_client.delete_load_balancer(load_balancer_arn: #{load_balancer.load_balancer_arn})")
              else
                elb_client.delete_load_balancer(load_balancer_arn: load_balancer.load_balancer_arn)
                Hako.logger.info "Deleted ELBv2 #{load_balancer.load_balancer_arn}"
              end
            else
              Hako.logger.info("ELBv2: #{load_balancer.load_balancer_arn} has multiple listeners. so ELBv2 is not remove.")
            end
          else
            if @dry_run
              Hako.logger.info("elb_client.delete_load_balancer(load_balancer_arn: #{load_balancer.load_balancer_arn})")
            else
              elb_client.delete_load_balancer(load_balancer_arn: load_balancer.load_balancer_arn)
              Hako.logger.info "Deleted ELBv2 #{load_balancer.load_balancer_arn}"
            end
          end
        else
          Hako.logger.info "ELBv2 #{name} doesn't exist"
        end

        target_group = describe_target_group
        if target_group
          if @dry_run
            Hako.logger.info("elb_client.delete_target_group(target_group_arn: #{target_group.target_group_arn})")
          else
            deleted = false
            30.times do
              begin
                elb_client.delete_target_group(target_group_arn: target_group.target_group_arn)
                deleted = true
                break
              rescue Aws::ElasticLoadBalancingV2::Errors::ResourceInUse => e
                Hako.logger.warn("#{e.class}: #{e.message}")
              end
              sleep 1
            end
            unless deleted
              raise Error.new("Cannot delete target group #{target_group.target_group_arn}")
            end
            Hako.logger.info "Deleted target group #{target_group.target_group_arn}"
          end
        end
      end

      # @return [String]
      def name
        "hako-#{@app_id}"
      end

      # @return [Hash]
      def load_balancer_params_for_service
        {
          target_group_arn: describe_target_group.target_group_arn,
          container_name: @elb_v2_config.fetch('container_name', 'front'),
          container_port: @elb_v2_config.fetch('container_port', 80),
        }
      end

      private

      def elb_client
        @elb_v2 ||= Aws::ElasticLoadBalancingV2::Client.new(region: @region)
      end
    end
  end
end
