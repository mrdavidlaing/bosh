# Copyright (c) 2009-2012 VMware, Inc.

module Bosh::Director
  module DeploymentPlan
    class ResourcePool
      include ValidationHelper

      # @return [String] Resource pool name
      attr_reader :name

      # @return [Integer] Expected resource pool size (in VMs)
      attr_reader :size

      # @return [DeploymentPlan] Deployment plan
      attr_reader :deployment_plan

      # @return [DeploymentPlan::Stemcell] Stemcell spec
      attr_reader :stemcell

      # @return [DeploymentPlan::Network] Network spec
      attr_reader :network

      # @return [Hash] Cloud properties
      attr_reader :cloud_properties

      # @return [Hash] Resource pool environment
      attr_reader :env

      # @return [Array<DeploymentPlan::IdleVm>] List of idle VMs
      attr_reader :idle_vms

      # @return [Array<DeploymentPlan::IdleVm] List of allocated idle VMs
      attr_reader :allocated_vms

      # @return [Integer] Number of active resource pool VMs
      attr_reader :active_vm_count

      # @return [Integer] Number of VMs reserved
      attr_reader :reserved_capacity

      # @param [DeploymentPlan] deployment_plan Deployment plan
      # @param [Hash] spec Raw resource pool spec from the deployment manifest
      def initialize(deployment_plan, spec)
        @deployment_plan = deployment_plan

        @name = safe_property(spec, "name", :class => String)
        @size = safe_property(spec, "size", :class => Integer)

        @cloud_properties =
          safe_property(spec, "cloud_properties", :class => Hash)

        stemcell_spec = safe_property(spec, "stemcell", :class => Hash)
        @stemcell = Stemcell.new(self, stemcell_spec)

        network_name = safe_property(spec, "network", :class => String)
        @network = @deployment_plan.network(network_name)

        if @network.nil?
          raise ResourcePoolUnknownNetwork,
                "Resource pool `#{@name}' references " +
                "an unknown network `#{network_name}'"
        end

        @env = safe_property(spec, "env", :class => Hash, :default => {})

        @idle_vms = []
        @allocated_vms = []
        @active_vm_count = 0
        @reserved_capacity = 0
        @reserved_errand_capacity = 0
      end

      # Returns resource pools spec as Hash (usually for agent to serialize)
      # @return [Hash] Resource pool spec
      def spec
        {
          "name" => @name,
          "cloud_properties" => @cloud_properties,
          "stemcell" => @stemcell.spec
        }
      end

      # Creates IdleVm objects for any missing resource pool VMs and reserves
      # dynamic networks for all idle VMs.
      # @return [void]
      def process_idle_vms
        # First, see if we need any data structures to balance the pool size
        missing_vm_count.times { add_idle_vm }

        # Second, see if some of idle VMs still need network reservations
        idle_vms.each do |idle_vm|
          unless idle_vm.has_network_reservation?
            idle_vm.use_reservation(reserve_dynamic_network)
          end
        end
      end

      # Tries to obtain one dynamic reservation in its own network
      # @raise [NetworkReservationError]
      # @return [NetworkReservation] Obtained reservation
      def reserve_dynamic_network
        reservation = NetworkReservation.new_dynamic
        @network.reserve!(reservation, "Resource pool `#{@name}'")
        reservation
      end

      # Adds a new VM to a list of managed idle VMs
      def add_idle_vm
        idle_vm = IdleVm.new(self)
        @idle_vms << idle_vm
        idle_vm
      end

      def allocate_vm
        allocated_vm = @idle_vms.pop
        @allocated_vms << allocated_vm
        allocated_vm
      end

      def deallocate_vm(idle_vm_cid)
        deallocated_vm = @allocated_vms.find { |idle_vm| idle_vm.vm.cid == idle_vm_cid }
        @allocated_vms.delete(deallocated_vm)
        @idle_vms << deallocated_vm
        deallocated_vm
      end

      # "Active" VM is a VM that is currently running a job
      # @return [void]
      def mark_active_vm
        @active_vm_count += 1
      end

      # Checks if there is enough capacity to run _extra_ N VMs,
      # raise error if not enough capacity
      # @raise [ResourcePoolNotEnoughCapacity]
      # @return [void]
      def reserve_capacity(n)
        needed = @reserved_capacity + n
        if needed > @size
          raise ResourcePoolNotEnoughCapacity,
                "Resource pool `#{@name}' is not big enough: " +
                "#{needed} VMs needed, capacity is #{@size}"
        end
        @reserved_capacity = needed
      end

      # Checks if there is enough capacity to run _up to_ N VMs,
      # raise error if not enough capacity.
      # Only enough capacity to run the largest errand is required,
      # because errands can only run one at a time.
      # @raise [ResourcePoolNotEnoughCapacity]
      # @return [void]
      def reserve_errand_capacity(n)
        needed = n - @reserved_errand_capacity

        if needed > 0
          reserve_capacity(needed)
          @reserved_errand_capacity = n
        end
      end

      private

      # Returns a number of VMs that need to be created in order to bring
      # this resource pool to a desired size
      # @return [Integer]
      def missing_vm_count
        @size - @active_vm_count - @idle_vms.size
      end
    end
  end
end
