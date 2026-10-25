import HomeKit

/// Use HomeKit identifiers, never translated category labels or accessory names.
enum DeviceSymbol {
    static func name(for accessory: HMAccessory) -> String {
        let category = accessory.category.categoryType
        if category == HMAccessoryCategoryTypeSensor || category == HMAccessoryCategoryTypeOther {
            let services = Set(accessory.services.map(\.serviceType))
            if services.contains(HMServiceTypeMotionSensor) { return "sensor" }
            if services.contains(HMServiceTypeOccupancySensor) { return "person.fill" }
            if services.contains(HMServiceTypeContactSensor) { return "door.left.hand.closed" }
            if services.contains(HMServiceTypeTemperatureSensor) { return "thermometer" }
            if services.contains(HMServiceTypeHumiditySensor) { return "humidity" }
            if services.contains(HMServiceTypeLeakSensor) { return "drop.triangle" }
            if services.contains(HMServiceTypeSmokeSensor) { return "smoke" }
            if services.contains(HMServiceTypeCarbonMonoxideSensor) { return "carbon.monoxide.cloud" }
            if services.contains(HMServiceTypeCarbonDioxideSensor) { return "carbon.dioxide.cloud" }
            if services.contains(HMServiceTypeAirQualitySensor) { return "aqi.medium" }
            if services.contains(HMServiceTypeLightSensor) { return "sun.max" }
        }
        switch category {
        case HMAccessoryCategoryTypeSecuritySystem: return "shield.lefthalf.filled"
        case HMAccessoryCategoryTypeBridge: return "network"
        case HMAccessoryCategoryTypeDoor: return "door.left.hand.closed"
        case HMAccessoryCategoryTypeDoorLock: return "lock"
        case HMAccessoryCategoryTypeFan: return "fan"
        case HMAccessoryCategoryTypeGarageDoorOpener: return "door.garage.closed"
        case HMAccessoryCategoryTypeIPCamera: return "web.camera"
        case HMAccessoryCategoryTypeLightbulb: return "lightbulb"
        case HMAccessoryCategoryTypeOutlet: return "poweroutlet.type.f"
        case HMAccessoryCategoryTypeProgrammableSwitch: return "button.programmable"
        case HMAccessoryCategoryTypeRangeExtender: return "wifi"
        case HMAccessoryCategoryTypeSwitch: return "switch.2"
        case HMAccessoryCategoryTypeThermostat: return "thermometer"
        case HMAccessoryCategoryTypeVideoDoorbell: return "video.doorbell"
        case HMAccessoryCategoryTypeWindow: return "window.vertical.closed"
        case HMAccessoryCategoryTypeWindowCovering: return "blinds.horizontal.closed"
        case HMAccessoryCategoryTypeAirPurifier: return "air.purifier"
        case HMAccessoryCategoryTypeAirHeater: return "heater.vertical"
        case HMAccessoryCategoryTypeAirConditioner: return "air.conditioner.horizontal"
        case HMAccessoryCategoryTypeAirHumidifier: return "humidifier"
        case HMAccessoryCategoryTypeAirDehumidifier: return "dehumidifier"
        case HMAccessoryCategoryTypeSprinkler: return "sprinkler"
        case HMAccessoryCategoryTypeFaucet: return "spigot"
        case HMAccessoryCategoryTypeShowerHead: return "shower"
        case HMAccessoryCategoryTypeTelevision: return "tv"
        case HMAccessoryCategoryTypeTelevisionSetTopBox: return "appletv"
        case HMAccessoryCategoryTypeTelevisionStreamingStick: return "tv"
        case HMAccessoryCategoryTypeWiFiRouter: return "wifi.router"
        case HMAccessoryCategoryTypeSpeaker: return "hifispeaker"
        case HMAccessoryCategoryTypeAudioReceiver: return "hifireceiver"
        case HMAccessoryCategoryTypeAirPort: return "wifi.router"
        case HMAccessoryCategoryTypeSensor: return "sensor"
        default: return "square.stack.3d.up"
        }
    }
}
