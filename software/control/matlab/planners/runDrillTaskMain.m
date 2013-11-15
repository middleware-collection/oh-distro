% The main program for the drill task

%% Setup our simulink objects and lcm monitor
r = RigidBodyManipulator(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'),struct('floating',true));
atlas = Atlas(strcat(getenv('DRC_PATH'),'/models/mit_gazebo_models/mit_robot_drake/model_minimal_contact_point_hands.urdf'));

lcm_mon = drillTaskLCMMonitor(atlas, useRightHand);
%% Wait for drill and wall affordance and create planner
publishPlans = true;
useRightHand = true;
useVisualization = false;
allowPelvisHeight = true;

[wall,drill] = lcm_mon.getWallAndDrillAffordances();
while isempty(wall) || isempty(drill)
  [wall,drill] = lcm_mon.getWallAndDrillAffordances();
end


finger_pt_on_hand = [0;.3;0];
finger_axis_on_hand = [0;1;0];

button_pub = drillButtonPlanner(r,atlas,drill.button_pos, drill.button_normal, drill.drill_axis,...
 finger_pt_on_hand, finger_axis_on_hand, useRightHand, useVisualization, publishPlans);

drill_pub = drillPlanner(r,atlas,drill.guard_pos, drill.drill_axis,...
  wall.normal, useRightHand, useVisualization, publishPlans, allowPelvisHeight);
drill_points = [wall.targets wall.targets(:,1)];

% drilling state machine initialization
segment_index = 1;
cut_lengths = sum((drill_points(:,2:end) - drill_points(:,1:end-1)).*(drill_points(:,2:end) - drill_points(:,1:end-1)));
[~,diagonal_index] = max(cut_lengths);

short_cut = .03;
long_cut = .1;

xtraj_nominal = []; %to know if we've got a plan
xtraj_button = []; %to know if we've got a plan

while(true)
  % Update wall
  new_wall = lcm_mon.getWallAffordance();
  if ~isempty(new_wall)
    if ~isequal(new_wall.normal, wall.normal) || ~isequal(new_wall.targets, wall.targets)
      wall = new_wall;
    end
    
    drill_pub = drill_pub.updateWallNormal(wall.normal);
    drill_points = [wall.targets wall.targets(:,1)];
  end
  
  [ctrl_type, ctrl_data] = lcm_mon.getDrillControlMsg();
  
  switch ctrl_type
    case lcm_mon.REFIT_DRILL
      new_drill = lcm_mon.getDrillAffordance();
      if ~isempty(new_drill)
        drill = new_drill;
        drill_pub = drill_pub.updateDrill(drill.guard_pos, drill.drill_axis);
      else
        send_status(4,0,0,'Cannot update drill, no affordance found');
      end
      
    case lcm_mon.RQ_NOMINAL_PLAN
      %hand picked joints that make for a decent guess
      q0_init = [zeros(6,1); 0.0355; 0.0037; 0.0055; zeros(12,1); -1.2589; 0.3940; 2.3311; -1.8152; 1.6828; zeros(6,1); -0.9071;0];
      
      target_centroid = mean(wall.targets,2);
      q0_init(1:3) = target_centroid - wall.normal*.5 - [0;0;.5];
      q0_init(6) = atan2(wall.normal(2), wall.normal(1));
      [xtraj_nominal,snopt_info_nominal,infeasible_constraint_nominal] = drill_pub.findDrillingMotion(q0_init, drill_points, true);
      
    case lcm_mon.RQ_WALKING_GOAL
      if ~isempty(xtraj_nominal)
        x_end = xtraj_nominal.eval(0);
        pose = [x_end(1:3); rpy2quat(x_end(4:6))];
        drill_pub.publishWalkingGoal(pose);
      else
        send_status(4,0,0,'Nominal trajectory not instantiated yet, cannot create a walking goal');
      end
      
    case lcm_mon.RQ_ARM_PREPOSE_PLAN
      if ~isempty(xtraj_nominal)
        q0 = lcm_mon.getStateEstimate();
     
        qf = xtraj_nominal.eval(0);
        qf = qf(1:34);
        posture_index = setdiff((1:r.num_q)',[drill_pub.joint_indices]');
        qf(posture_index) = q_wall(posture_index);
        kinsol = r.doKinematics(qf);
        drill_f = r.forwardKin(kinsol,drill_pub.hand_body,drill_pub.drill_pt_on_hand);
        
        [xtraj_arm_init,snopt_info_arm_init,infeasible_constraint_arm_init] = drill_pub.createInitialReachPlan(q0, drill_f - .1*wall.normal, 5);
      else
        send_status(4,0,0,'Nominal trajectory not instantiated yet, cannot create a walking goal');
      end
      
    case lcm_mon.RQ_NOMINAL_FIXED_PLAN
      q0 = lcm_mon.getStateEstimate();
      [xtraj_nominal,snopt_info_nominal,infeasible_constraint_nominal] = drill_pub.findDrillingMotion(q0, drill_points, false);
      
    case lcm_mon.RQ_PREDRILL_PLAN
      segment_index = 1; % RESETS THE SEGMENT INDEX!
      q0 = lcm_mon.getStateEstimate();
      x_drill_reach = wall.targets(:,1) - .1*wall.normal;
      
      [xtraj_reach,snopt_info_reach,infeasible_constraint_reach] = drill_pub.createInitialReachPlan(q0, x_drill_reach, 5);
    case lcm_mon.RQ_DRILL_IN_PLAN
      q0 = lcm_mon.getStateEstimate();
      [xtraj_drill,snopt_info_drill,infeasible_constraint_drill] = drill_pub.createDrillingPlan(q0, wall.targets(:,1), 5);
      
    case lcm_mon.RQ_NEXT_DRILL_PLAN
      q0 = lcm_mon.getStateEstimate();
        
      kinsol = r.doKinematics(q0);
      drill0 = r.forwardKin(kinsol, drill_pub.hand_body, drill.guard_pos);
      
      in_goal = norm(drill0 - drill_points(:,segment_index+1)) < .05;
      
      if in_goal
        segment_index = segment_index + 1;
        if segment_index == diagonal_index,
          cut_length = short_cut;
        elseif segment_index > size(drill_points,2)
          segment_index = 1; % reset to the beginning, may not be a great idea
        else
          cut_length = long_cut;
        end
      else
        cut_length = long_cut;
      end
      
      segment_dir = (drill_points(:,segment_index+1) -drill_points(:,segment_index));
      segment_dir = segment_dir/norm(segment_dir);
      
      line_param = -(drill_points(:,segment_index) - drill0)'*(drill_points(:,segment_index+1) - drill_points(:,segment_index))/norm(drill_points(:,segment_index+1)-drill_points(:,segment_index))^2;
      
      nearest_point = drill_points(:,segment_index) + line_param*(drill_points(:,segment_index+1) -drill_points(:,segment_index));
      
      dist_to_cut = norm(drill0 - nearest_point);
      if dist_to_cut < .07
        cut_param = min(1,cut_length/cut_lengths(segment_index) + line_param);
        drill_target = drill_points(:,segment_index) + cut_param*(drill_points(:,segment_index+1) -drill_points(:,segment_index));
      else
        drill_target = nearest_point;
      end
      
      [xtraj_drill,snopt_info_drill,infeasible_constraint_drill] = drill_pub.createDrillingPlan(q0, drill_target, 5);
    case lcm_mon.RQ_DRILL_TARGET_PLAN
      % create wall coordinate frame
      wall_z = [0;0;1];
      wall_z = wall_z - wall_z'*wall.normal*wall.normal;
      wall_z = wall_z/norm(wall_z);
      wall_y = cross(wall_z, wall.normal);
      
    case lcm_mon.RQ_DRILL_DELTA_PLAN
      if sizecheck(ctrl_data, [3 1])
        delta = ctrl_data(1:3);
        q0 = lcm_mon.getStateEstimate();
        
        kinsol = r.doKinematics(q0);
        drill0 = r.forwardKin(kinsol, drill_pub.hand_body, drill.guard_pos);
        drill_target = drill0 + delta;
        [xtraj_drill,snopt_info_drill,infeasible_constraint_drill] = drill_pub.createDrillingPlan(q0, drill_target, 5);
      else
        send_status(4,0,0,'Invalid size of control data. Expected 3x1');
      end
    case lcm_mon.RQ_BUTTON_PREPOSE_PLAN
      q0 = lcm_mon.getStateEstimate();
      last_button_offset = [-.1;0;0];
      [xtraj_button,snopt_info_button,infeasible_constraint_button] = button_pub.createPrePokePlan(q0, 5);
    case lcm_mon.RQ_BUTTON_DELTA_PLAN
      if sizecheck(ctrl_data, [3 1])
        
        if ~isempty(xtraj_button)
          xlast = xtraj_button.eval(xtraj_button.tspan(2));
          %         q0 = lcm_mon.getStateEstimate();
          q0 = xlast(1:r.getNumDOF);
          button_offset = last_button_offset + ctrl_data(1:3);
          last_button_offset = button_offset;
          [xtraj,snopt_info,infeasible_constraint] = button_pub.createPokePlan(q0, button_offset, 5);
          %         % use back and off-hand joints from last plan
          %         q0(button_pub.button_joint_indices) = xlast(button_pub.button_joint_indices);
          %         q0(button_pub.back_joint_indices) = xlast(button_pub.back_joint_indices);
        else
          send_status(4,0,0,'Pre-button trajectory not instantiated yet, cannot create a poking plan');
        end
      else
        send_status(4,0,0,'Invalid size of control data. Expected 3x1');
      end
  end
  pause(.05);
end