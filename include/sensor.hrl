%--------------- MAIN HEADER -----------------
%    2b        3b         3b
%    TypeMsg  TypeSensor  ADD
%---------------------------------------------

-define(TYPEMSGMAX, 3).
-define(TYPESENSORMAX, 5).

-define(LIST_ALL_SENSORS, [no_sensor,
           pressure,
           conductivity,
           oxygen]).

-define(TYPEMSG2NUM(N),
  case N of
      error  -> 0;
      get_data  -> 1;
      recv_data  -> 2
  end).

-define(TYPESENSOR2NUM(N),
  case N of
      no_sensor  -> 0;
      pressure   -> 1;
      conductivity -> 2;
      oxygen -> 3
  end).

-define(NUM2TYPEMSG(N),
  case N of
      0 -> error;
      1 -> get_data;
      2 -> recv_data
  end).

-define(NUM2TYPESENSOR(N),
  case N of
      0 -> no_sensor;
      1 -> pressure;
      2 -> conductivity;
      3 -> oxygen
  end).