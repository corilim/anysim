%   Simple test of the DiffuseSim toolbox
%   (c) 2019. Ivo Vellekoop
%

% Note: in this simulation, all axes (including the time axis)
% are in micrometers. The absorbtion coefficient and the diffusion
% coeffecient both given in unit [um] and [1/um], respectively.
% To scale to time in seconds and diffusion coefficient in um^2/s just
% divide or multiply by c (in um/s)
%

% Set up size of simulation domain and number of grid points in x,y,z,t 
% dimensions.
N = 256;
opt.pixel_size = {0.5 'um'};
opt.N = [N, 1, 1, 1]; %Nx, Ny, Nz, t   (constant in z and t)
opt.boundaries.periodic = [false, true, true, true];
opt.boundaries.width = 500;
opt.boundaries.quality = 10;
opt.gpu_enabled = false;
opt.termination_condition.handle = @tc_fixed_iteration_count;
opt.termination_condition.iteration_count = 400;
opt.callback.interval = 10;
opt.callback.handle = @DisplayCallback;
opt.callback.cross_section = @(u) u(4,:,ceil(end/2));
opt.callback.show_boundaries = true;
opt.V_max = 0.95;

%% Construct medium 
% Layered medium with constant absorption and diffusion coefficients
a = 0;%0.02;    % absorption coefficient (1/m)
Dslab = 25;
D = ones(N, 1, 1, 1) * Dslab;    % diffusion length (m)
zl = 20; % start of sample
zr = N-20; % end of sample
%z0 = 128-zl; % position of source relative to start of sample (transport length)
z0 = 20;
%z0 = zr-zl-15; % position of source relative to start of sample (transport length)

D(1:zl-1) = Inf;  % 'air'
D((zr+1):end) = Inf;
sim = DiffuseSim(D, a, opt);
%clear mu_a D;

%%
source = sim.define_source(ones(1,1,opt.N(2)), [4,zl+z0,1,1,1]); % intensity-only source (isotropic) at t=0
%source = sim.define_source(ones(1,1,opt.N(2)), [1,zl,1,1,1]); % intensity-only source (isotropic) at t=0

u = sim.exec(source);

%%
z = sim.grid.crop(sim.grid.coordinates(1));
Iz = squeeze(u(4,:,ceil(end/2)));
Fz = squeeze(u(1,:,ceil(end/2)));
plot(z, Iz);
hold on;
% compute transmission coefficient (assuming no aborption)
TsimI = Iz(end)/(Iz(1)+Iz(end));
Tsim = Fz(end)/(-Fz(1)+Fz(end));
disp(Tsim);



% theoretical intensity distribution (normalized to same height as simulation):
ell = z0;
ze = 2/3*ell;
L = zr-zl-1;
T = (ell+ze)/(L+2*ze);

% theoretical maximum intensity (source amplitude = 1)
Imaxth = opt.pixel_size{1,1}/Dslab * T * (L - ell + ze);

I_th = interp1([zl-ze, zl+z0, zr+ze], [0, Imaxth,0], 1:N);
plot(z, I_th);