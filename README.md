# EviNS: Framework for Development of Underwater Acoustic Sensor Networks and Positioning Systems

Evologics intelligent Networking Software Framework (EviNS Framework) follows a paradigm of event driven programming,
each module is explicitly defined in form of a pushdown automata and is driven purely by discrete events generated 
internally by event handles, by timers or externally by interface processors. The task of the interface processor is
to provide the mechanism to receive and parse this data, and pass it to the module. The task of the module is
to handle this event, update the state and pass back to the interface processor tuples, to be converted to the 
appropriate format and delivered via the appropriate interface.

The framework has relatively moderate system requirements and can be run directly on the EvoLogics acoustic modems'
hardware or can be used with the DMACE – a real-time emulator of EvoLogics underwater acoustic modems. The emulator
provides a fully-featured emulation of the data-link layer and includes a phenomenological simulator of the physical
layer that accounts for signal propagation delays, multipath propagation, data packet collisions, packet synchronization
errors and bit errors with a user-defined bit error rate. EviNS along with the DMACE builds comprehensive set of tools
for development, testing, deployment and operation of a great variety of communication and positioning solutions for
underwater acoustic sensor networks (UASN). Open source modules supporting other acoustic modems can be added by the
modem suppliers or keen developers.

Documentation for the framework can be found on the https://github.com/okebkal/evins/wiki (in progress)
