function qtraj_rescaled = rescalePlanTiming(qtraj, qd_max, acceleration_param)
  % @param acceleration_param - Scalar parameter greater than or equal to 2 that
  %                             adjusts the acceleration profile. Higher values
  %                             yield more gradual accelerations. @defualt 3

  if nargin < 3, acceleration_param = 2; end
  
  % Scale timing to obey joint velocity limits
  % Create initial spline
  t = linspace(qtraj.tspan(1), qtraj.tspan(2),200);
  q_path = eval(qtraj, t); %#ok

  % Determine max joint velocity at midpoint of  each segment
  t_mid = mean([t(2:end); t(1:end-1)],1);
  qd_mid = qtraj.fnder().eval(t_mid);
  scale_factor = max(abs(bsxfun(@rdivide, qd_mid, qd_max)), [], 1);

  % Adjust durations to keep velocity below max
  t_scaled = [0, cumsum(diff(t).*scale_factor)];
  tf = t_scaled(end);

  % Warp time to give gradual acceleration/deceleration
  t_warped = tf*warpTime(t_scaled/tf, acceleration_param);
  [t_unique, idx_unique] = unique(t_warped,'stable');

  qtraj_rescaled = PPTrajectory(pchip(t_unique, q_path(:,idx_unique)));
end
