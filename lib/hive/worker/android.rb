require 'hive/worker'
require 'hive/messages/android_job'

module Hive
  class PortReserver
    attr_accessor :ports
    def initialize
      self.ports = {}
    end

    def reserve(queue_name)
      self.ports[queue_name] = Hive.data_store.port.assign("#{queue_name}")
      self.ports[queue_name]
    end
  end

  class Worker
    class Android < Worker

      attr_accessor :device

      def initialize(device)
        @ports = PortReserver.new
        @adb_server_port = Hive.data_store.port.assign("#{device['name']} - adb")
        device.merge!({"device_api" => DeviceAPI::Android.device(device['serial'])})
        set_device_status('idle')
        self.device = device
        super(device)
      end

      def pre_script(job, file_system, script)
        set_device_status('busy')
        script.set_env "TEST_SERVER_PORT", @adb_server_port

        # TODO: Allow the scheduler to specify the ports to use
        script.set_env "CHARLES_PROXY_PORT",  @ports.reserve(queue_name: 'Charles')
        script.set_env "APPIUM_PORT",         @ports.reserve(queue_name: 'Appium')
        script.set_env "BOOTSTRAP_PORT",      @ports.reserve(queue_name: 'Bootstrap')
        script.set_env "CHROMEDRIVER_PORT",   @ports.reserve(queue_name: 'Chromedriver')

        script.set_env 'ADB_DEVICE_ARG', self.device['serial']

        FileUtils.mkdir(file_system.home_path + '/build')
        apk_path = file_system.home_path + '/build/' + 'build.apk'

        script.set_env "APK_PATH", apk_path
        file_system.fetch_build(job.build, apk_path) if job.build

        DeviceAPI::Android::Signing.sign_apk({apk: apk_path, resign: true})

        "#{self.device['serial']} #{@ports.ports['Appium']} #{apk_path} #{file_system.results_path}"
      end

      def job_message_klass
        Hive::Messages::AndroidJob
      end

      def post_script(job, file_system, script)
        @log.info('Post script')
        @ports.ports.each do |name, port|
          Hive.data_store.port.release(port)
        end
        set_device_status('idle')
      end

      def device_status
        details = Hive.devicedb('Device').find(@options['id'])
        if details.key?('status')
          @state = details['status']
          details['status']
        else
          @state
        end
      end

      def set_device_status(status)
        @state = status
        begin
          details = Hive.devicedb('Device').poll(@options['id'], status)
          if details.key?('status')
            details['status']
          else
            @state
          end
        rescue
          @state
        end
      end
    end
  end
end
