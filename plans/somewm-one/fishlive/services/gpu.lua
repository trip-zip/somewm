---------------------------------------------------------------------------
--- GPU service — NVIDIA via NVML LuaJIT FFI (zero subprocess overhead).
--
-- Direct FFI calls to libnvidia-ml.so: ~0.7µs per poll vs 17ms nvidia-smi.
-- Falls back to nvidia-smi subprocess if FFI unavailable.
--
-- @module fishlive.services.gpu
---------------------------------------------------------------------------

local service = require("fishlive.service")
local broker = require("fishlive.broker")

-- Try NVML FFI first (LuaJIT only, 24000x faster than nvidia-smi)
local nvml_poll = nil

local ok, ffi = pcall(require, "ffi")
if ok then
	local load_ok, nvml = pcall(ffi.load, "nvidia-ml")
	if load_ok then
		ffi.cdef[[
			typedef struct nvmlDevice_st* nvmlDevice_t;
			typedef int nvmlReturn_t;
			typedef struct { unsigned int gpu; unsigned int memory; } nvmlUtilization_t;
			nvmlReturn_t nvmlInit_v2(void);
			nvmlReturn_t nvmlShutdown(void);
			nvmlReturn_t nvmlDeviceGetHandleByIndex_v2(unsigned int index, nvmlDevice_t* device);
			nvmlReturn_t nvmlDeviceGetTemperature(nvmlDevice_t device, int sensorType, unsigned int* temp);
			nvmlReturn_t nvmlDeviceGetUtilizationRates(nvmlDevice_t device, nvmlUtilization_t* utilization);
			nvmlReturn_t nvmlDeviceGetName(nvmlDevice_t device, char* name, unsigned int length);
		]]

		local device = ffi.new("nvmlDevice_t[1]")
		local temp = ffi.new("unsigned int[1]")
		local util = ffi.new("nvmlUtilization_t[1]")
		local name_buf = ffi.new("char[256]")
		local initialized = false
		local gpu_name = nil

		local function nvml_init()
			if initialized then return true end
			if nvml.nvmlInit_v2() ~= 0 then return false end
			if nvml.nvmlDeviceGetHandleByIndex_v2(0, device) ~= 0 then
				nvml.nvmlShutdown()
				return false
			end
			nvml.nvmlDeviceGetName(device[0], name_buf, 256)
			gpu_name = ffi.string(name_buf)
			initialized = true
			return true
		end

		nvml_poll = function()
			if not nvml_init() then return nil end
			if nvml.nvmlDeviceGetUtilizationRates(device[0], util) ~= 0 then return nil end
			if nvml.nvmlDeviceGetTemperature(device[0], 0, temp) ~= 0 then return nil end
			return {
				usage = tonumber(util[0].gpu),
				temp = tonumber(temp[0]),
				name = gpu_name,
				icon = "󰢮",
			}
		end
	end
end

-- Build service with FFI poll or nvidia-smi fallback
local s
if nvml_poll then
	s = service.new {
		signal   = "data::gpu",
		interval = 3,  -- FFI is cheap (~0.7µs), can poll frequently
		poll_fn  = nvml_poll,
	}
else
	-- Fallback: nvidia-smi subprocess (~17ms per call)
	s = service.new {
		signal   = "data::gpu",
		interval = 10,
		command  = "nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,name --format=csv,noheader,nounits 2>/dev/null",
		parser   = function(stdout)
			if not stdout or stdout == "" then return nil end
			local usage, temp, name = stdout:match("(%d+),%s*(%d+),%s*(.+)")
			if not usage then return nil end
			return {
				usage = tonumber(usage),
				temp = tonumber(temp),
				name = name:gsub("%s+$", ""),
				icon = "󰢮",
			}
		end,
	}
end

broker.register_producer("data::gpu", s)
return s
