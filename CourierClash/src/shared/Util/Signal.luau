--!strict
-- Minimal single-argument signal for cross-system events
-- (e.g. Parcel.Delivered). Handlers run synchronously in connect order.

export type Connection = {
	disconnect: () -> (),
}

export type Signal<T> = {
	connect: (handler: (T) -> ()) -> Connection,
	fire: (value: T) -> (),
}

local Signal = {}

function Signal.new<T>(): Signal<T>
	local handlers: { (T) -> () } = {}

	local function connect(handler: (T) -> ()): Connection
		table.insert(handlers, handler)
		return {
			disconnect = function()
				local index = table.find(handlers, handler)
				if index then
					table.remove(handlers, index)
				end
			end,
		}
	end

	local function fire(value: T)
		-- copy so handlers may disconnect themselves while firing
		for _, handler in table.clone(handlers) do
			handler(value)
		end
	end

	return { connect = connect, fire = fire }
end

return Signal
