function INSCompensator = init_INSCompensator()


INSCompensator.utime = 0;
INSCompensator.biases.bg = [0;0;0];
INSCompensator.biases.ba = [0;0;0];
INSCompensator.dE_l = [0;0;0];
INSCompensator.dbQb = [1;0;0;0];
INSCompensator.dV_l = [0;0;0];
INSCompensator.dP_l = [0;0;0];
