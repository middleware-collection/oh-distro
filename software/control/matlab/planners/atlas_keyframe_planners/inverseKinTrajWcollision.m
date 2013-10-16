function [xtraj,info,infeasible_constraint] = inverseKinTrajWcollision(obj,collision_status,t,q_seed_traj,q_nom_traj,varargin)
% The interface is the same as inverseKinTraj
% @param collision_status             - 0, no validation, no optimizatoin with collision
%                                     - 1, validation only, no optimization
%                                     - 2, optimization with collision constraint
if(isa(varargin{end},'IKoptions'))
  ikoptions = varargin{end};
  varargin = varargin(1:end-1); 
else
  ikoptions = IKoptions(obj);
end
collision_constraint_cell = {};
other_constraint_cell = {};
for i = 1:length(varargin)
  if(isa(varargin{i},'AllBodiesClosestDistanceConstraint'))
    collision_constraint_cell = [collision_constraint_cell varargin(i)];
  elseif(isa(varargin{i},'DrakeMexPointer'))
    if strcmp(varargin{i}.name,'AllBodiesClosestDistanceConstraint')
      error('Please construct MATLAB AllBodiesClosestDistanceConstraint object');
    end
  else
    other_constraint_cell = [other_constraint_cell,varargin(i)];
  end
end
if(collision_status == 0 || collision_status == 1)
  [xtraj,info,infeasible_constraint] = inverseKinTraj(obj,t,q_seed_traj,q_nom_traj,other_constraint_cell{:},ikoptions);
end
nq = obj.getNumDOF();
if(collision_status == 1)
  for i = 1:length(t)
    xi = xtraj.eval(t(i));
    qi = xi(1:nq);
    for j = 1:length(collision_constraint_cell)
      if(collision_constraint_cell{j}.isTimeValid(t(i)))
        [collisionAvoidFlag, dist,ptsA,ptsB,idxA,idxB] = collision_constraint_cell{j}.checkConstraint(qi);
        if(~collisionAvoidFlag)
          for k = 1:length(dist)
            send_status(4,0,0,sprintf('t=%4.2f,Dist from %s to %s is %f\n',...
              t(i),...
              sendNameString(collision_constraint_cell{j},idxA),...
              sendNameString(collision_constraint_cell{j},idxB),...
              dist(k)));
          end
        end
      end
    end
  end
elseif(collision_status == 2)
  [xtraj,info,infeasible_constraint] = inverseKinTraj(obj,t,q_seed,q_nom,collision_constraint_cell{:},other_constraint_cell{:},ikoptions);
end
end

function name_str = sendNameString(collision_constraint,body_ind)
robotnum = collision_constraint.robot.getBody(body_ind).robotnum;
if(robotnum == 1) % atlas
  name_str = collision_constraint.robot.getBody(body_ind).linkname;
else % affordance
  name_str = collision_constraint.robot.name{robotnum};
end
end