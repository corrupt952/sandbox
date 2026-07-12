import Foundation

class Item {
    let name: String
    let description: String

    init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

class Room {
    let name: String
    let description: String
    var exits: [String: Room] = [:]
    var items: [Item] = []

    init(name: String, description: String) {
        self.name = name
        self.description = description
    }

    func addExit(direction: String, room: Room) {
        exits[direction] = room
    }

    func addItem(_ item: Item) {
        items.append(item)
    }
}

class GameEngine {
    var currentRoom: Room
    var inventory: [Item] = []
    var isRunning = true

    init(startRoom: Room) {
        self.currentRoom = startRoom
    }

    func run() {
        print("--- Swift Text Adventure Engine ---")
        print("Commands: look, go [direction], take [item], inventory, use [item], exit")
        print("----------------------------------")

        while isRunning {
            print("\n[\(currentRoom.name)]")
            let roomInfo = currentRoom.description + (currentRoom.items.isEmpty ? "" : "\nItems here: " + currentRoom.items.map { $0.name }.joined(separator: ", "))
            print(roomInfo)
            print("> ", terminator: "")

            guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !input.isEmpty else {
                continue
            }

            processCommand(input)
        }
    }

    private func processCommand(_ input: String) {
        let parts = input.split(separator: " ")
        let command = String(parts[0])
        let argument = parts.count > 1 ? String(parts[1...].joined(separator: " ")) : ""

        switch command {
        case "exit":
            print("Goodbye!")
            isRunning = false
        case "look":
            print(currentRoom.description)
        case "go":
            if let nextRoom = currentRoom.exits[argument] {
                currentRoom = nextRoom
                print("You move to \(currentRoom.name).")
            } else {
                print("You cannot go '\(argument)' from here.")
            }
        case "take":
            if let index = currentRoom.items.firstIndex(where: { $0.name == argument }) {
                let item = currentRoom.items.remove(at: index)
                inventory.append(item)
                print("You took the \(item.name).")
            } else {
                print("There is no \(argument) here.")
            }
        case "inventory":
            if inventory.isEmpty {
                print("Your inventory is empty.")
            } else {
                print("You are carrying: " + inventory.map { $0.name }.joined(separator: ", "))
            }
        case "use":
            if let item = inventory.first(where: { $0.name == argument }) {
                print("You use the \(item.name). Nothing happens yet...")
                // Logic for 'use' can be expanded here
            } else {
                print("You don't have a \(argument).")
            }
        default:
            print("Unknown command: \(command)")
        }
    }
}

// --- Game Setup ---

let startRoom = Room(name: "Dungeon Cell", description: "A cold, damp cell. A heavy iron door leads north.")
let hallway = Room(name: "Dark Hallway", description: "A long corridor lit by flickering torches. A path leads south back to your cell and east into a library.")
let library = Room(name: "Ancient Library", description: "Shelves full of dusty books surround you. A door leads west back to the hallway.")

// Items
let key = Item(name: "key", description: "A rusty iron key.")
let book = Item(name: "book", description: "An old, leather-bound book.")

// Setup Connections
startRoom.addExit(direction: "north", room: hallway)
hallway.addExit(direction: "south", room: startRoom)
hallway.addExit(direction: "east", room: library)
library.addExit(direction: "west", room: hallway)

// Place Items
startRoom.addItem(key)
library.addItem(book)

let engine = GameEngine(startRoom: startRoom)
engine.run()
