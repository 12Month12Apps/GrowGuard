<h1>
  Grow Guard
  <img src="./GrowGuard/Assets.xcassets/AppIcon.appiconset/AppIcon1.png"
           align="right" width="128" height="128"/>
</h1>


Grow Guard is my take on a smart plant monitor app. It communicates with the Xiaomi FlowerCare Sensor. 

## Note:
This project is part of my 12 Month 12 Apps challenge, build as MVP to see if there is some intresst for this product. Not the cleanest code, would not recommend to copy it to your project. It is build as quick as possible. 

## Features 

- Add Multple sensors to your App and see the data (Moisture, Light, Soil)
- Use Siri Intent (Shortcut) to read the data daily in background (I found this the best way to get constant data without opening the app)
- Get reminders to water your plants (comming soon!)

## Known bugs:

- Data gets mixed between plants if they have the same name, thought I already changed this but there still is some place where it isn't. Will fix this soon!
- History data from the sensor is not read, but not sure if this is needed


## GrowGuard iOS App Architecture Diagram:

  ┌─────────────────────────────────────────────────────────────────────┐
  │                           GrowGuard iOS App                          │
  ├─────────────────────────────────────────────────────────────────────┤
  │                              UI Layer                               │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │   ContentView   │  │  OverviewList   │  │  DeviceDetails  │     │
  │  │   (TabView)     │  │   (Device       │  │   (Sensor       │     │
  │  │                 │  │    List)        │  │    Charts)      │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  │           │                     │                     │              │
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │   AddDevice     │  │  OnboardingView │  │   SettingsView  │     │
  │  │  (BLE Scanner)  │  │                 │  │                 │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  ├─────────────────────────────────────────────────────────────────────┤
  │                          ViewModel Layer                            │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │ ContentViewModel│  │OverviewListVM   │  │DeviceDetailsVM  │     │
  │  │                 │  │                 │  │                 │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  │           │                     │                     │              │
  │  ┌─────────────────┐            │                     │              │
  │  │AddDeviceViewModel│           │                     │              │
  │  │                 │            │                     │              │
  │  └─────────────────┘            │                     │              │
  │           │                     │                     │              │
  ├─────────────────────────────────────────────────────────────────────┤
  │                        Service Layer                                │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │RepositoryManager│  │PlantMonitorSvc  │  │   DeviceManager │     │
  │  │   (Singleton)   │  │                 │  │   (Singleton)   │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  │           │                     │                     │              │
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │FlowerCareManager│  │   FlowerSearch  │  │  NavigationSvc  │     │
  │  │   (BLE/IoT)     │  │   (SQLite DB)   │  │                 │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  ├─────────────────────────────────────────────────────────────────────┤
  │                      Repository Layer                               │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │FlowerDeviceRepo │  │ SensorDataRepo  │  │OptimalRangeRepo │     │
  │  │                 │  │                 │  │                 │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  │           │                     │                     │              │
  │  ┌─────────────────┐            │                     │              │
  │  │  PotSizeRepo    │            │                     │              │
  │  │                 │            │                     │              │
  │  └─────────────────┘            │                     │              │
  ├─────────────────────────────────────────────────────────────────────┤
  │                         DTO Layer                                   │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │FlowerDeviceDTO  │  │ SensorDataDTO   │  │OptimalRangeDTO  │     │
  │  │                 │  │                 │  │                 │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  │           │                     │                     │              │
  │  ┌─────────────────┐            │                     │              │
  │  │   PotSizeDTO    │            │                     │              │
  │  │                 │            │                     │              │
  │  └─────────────────┘            │                     │              │
  ├─────────────────────────────────────────────────────────────────────┤
  │                        Data Layer                                   │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │   DataService   │  │   Core Data     │  │   SQLite DB     │     │
  │  │   (Singleton)   │  │   Models        │  │  (FlowerSearch) │     │
  │  │                 │  │                 │  │                 │     │
  │  │ ┌─────────────┐ │  │ ┌─────────────┐ │  │ ┌─────────────┐ │     │
  │  │ │Main Context │ │  │ │FlowerDevice │ │  │ │   Species   │ │     │
  │  │ │Background   │ │  │ │SensorData   │ │  │ │   Families  │ │     │
  │  │ │Context      │ │  │ │OptimalRange │ │  │ │             │ │     │
  │  │ │             │ │  │ │PotSize      │ │  │ │             │ │     │
  │  │ └─────────────┘ │  │ └─────────────┘ │  │ └─────────────┘ │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  ├─────────────────────────────────────────────────────────────────────┤
  │                       Hardware Layer                                │
  ├─────────────────────────────────────────────────────────────────────┤
  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐     │
  │  │      BLE        │  │    Bluetooth    │  │    Sensors      │     │
  │  │   FlowerCare    │  │   Peripheral    │  │   (Temperature, │     │
  │  │   Manager       │  │   Scanner       │  │   Moisture,     │     │
  │  │                 │  │                 │  │   Light, etc.)  │     │
  │  └─────────────────┘  └─────────────────┘  └─────────────────┘     │
  └─────────────────────────────────────────────────────────────────────┘

  Key Architecture Patterns:

  1. MVVM (Model-View-ViewModel)

  - Views: SwiftUI views for UI
  - ViewModels: @Observable classes managing state
  - Models: DTOs for clean data transfer

  2. Repository Pattern

  - Abstract Interfaces: FlowerDeviceRepository, SensorDataRepository
  - Concrete Implementations: CoreDataFlowerDeviceRepository, etc.
  - Dependency Injection: Via RepositoryManager

  3. Clean Architecture Layers

  - Presentation: SwiftUI Views + ViewModels
  - Domain: DTOs + Repository Interfaces
  - Data: Core Data + SQLite implementations

  4. Singleton Services

  - DataService: Core Data management
  - RepositoryManager: Repository factory
  - DeviceManager: Shared device state
  - FlowerCareManager: BLE communication

  5. Data Flow

  Hardware → BLE → FlowerCareManager → Repository → DTO → ViewModel → View


## Join the beta:

https://github.com/12Month12Apps/GrowGuardTest
