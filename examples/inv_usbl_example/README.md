# Compile:

```bash
make
```

# Run:

```bash
CODE_LOADING_MODE=interactive _rel/ext_example/bin/ext_example console
```

  in another terminal window run:
```bash

source node local addr 2:

nc 10.42.0.2 9200
AT*SENDIM,1,1,ack,t

node with local addr 1:

nc 10.42.0.1 9200
RECVIM...
UBSLANGLES,....


The node with local addr 1 generates a PBM containing info 
<"L", local_bearing, local_elevation, roll, pitch, yaw>

and sends it to the node with local addr 2
```

