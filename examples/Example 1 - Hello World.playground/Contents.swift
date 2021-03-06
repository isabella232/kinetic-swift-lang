//: ## Example 1 - Hello World

import Kinetic

//: First connect to a `KineticDevice` by creating a `KineticSession`
let c = try Kinetic.connect("localhost", port: 8123)

//: Write a key/value pair
try c.put("hello", value: "world")

//: Read the value back
let x = try c.get("hello")

//: The Strings on the methods are just for convenience
//: the actual values are byte arrays `[UInt8]`
print("Received: \(x.value!.toUtf8String())")

//: We are done
c.close()
c.connected
