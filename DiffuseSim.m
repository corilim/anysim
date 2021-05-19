classdef DiffuseSim < GridSim
    %DIFFUSESIM Solves the diffusion equation for inhomogeneous media
    %   Built on the AnySim framework.
    %   Solves either dynamic or steady state diffusion equation.
    %   Position-dependent absorption
    %   Position-dependent diffusion tensor or scalar coefficient
    %
    %   (c) 2021. Ivo Vellekoop
    methods
        function obj = DiffuseSim(D, a, opt)
            % DIFFUSESIM Simulation object for a solving the diffusion
            % equation.
            %
            % sim = DiffuseSim(D, MUA, OPT) contructs a new simulation object
            % with the specified diffusion coefficient D and absoption
            % coefficient MUA.
            %
            % Note: in the sample code, for simplicity D and MUA are
            % specified in [um] and [um^-1], respectively, and micrometers
            % are used as unit for the temporal dimension.
            % Conversion to the regular units is done by scaling with  
            % the wave velocity: D -> D c and t -> t/c.
            %
            % Note: we always use 4 components (Fx, Fy, Fz, I). For
            % simulations in 1 or 2 dimensions, this approach is 
            % slightly wasteful since Fz and/or Fx will be 0.
            %
            % D Diffusion coefficient or 3x3 diffusion tensor.
            %   The dimensions of D depend on the OPT.potential_type setting.
            %   Assuming grid dimensions Nx x Ny x Nz x Nt the size must be:
            %   'scalar' size(D) = [Nx, Ny, Nz, Nt]
            %   'diagonal' size(D) = [3, Nx, Ny, Nz, Nt]
            %   'tensor' size (D) = [3, 3, Nx, Ny, Nz, Nt]
            %   In all cases, D must be strict positive definite.
            %   Singleton dimensions are expanded automatically.
            %
            % MUA Absorption coefficient.
            %   Must be a positive scalar (may be 0) of size [Nx, Ny, Nz,
            %   Nt]. Singleton dimensions are expanded automatically.
            %
            % OPT Options structure
            %   .potential_type Any of the options 'scalar' (default), 'diagonal', 'tensor'
            %                   This option determines how the D array is
            %                   interpreted (see above)
            %   .pixel_size     Grid spacing, specified as, for example
            %                   [5 'um', 10 'um', 5 'um']. (default 1 '-')
            %   .interfaces     Specification of the interfaces between
            %                   the diffusive medium and the 'outside'
            %                   This is a sparse [3, Nx, Ny, Nz, Nt] matrix
            %                   with the three components indicating
            %                   the outward pointing normal of the
            %                   interface times 𝜏=(1+R)/(1-R), with
            %                   R the angle-averaged reflectivity of the 
            %                   interface
            %   todo: allow indexed description for D (use an index to look up 
            %   the D tensor for each voxel).
            
            %% Set defaults
            opt.real_signal = true;
            defaults.pixel_size = {1, '-'};
            opt = set_defaults(defaults, opt);
            
            %% Construct base class
            obj = obj@GridSim(4, opt); 
            
            %% Construct components: operators for medium, propagator and transform
            obj.medium  = obj.makeMedium(D, a);
            obj.transform  = FourierTransform(obj.opt);
            obj.propagator = obj.makePropagator();
        end
    end
    methods (Access = protected)        
        function medium = makeMedium(obj, D, a)
            % Construct medium operator G=1-V
            %
            %    [      0]    
            %V = [  Q   0]
            %    [      0]
            %    [0 0 0 a]
            %
            %% Invert D, then add entries for a
            D = data_array(D, obj.opt); % convert D to data array (put on gpu if needed, change precision if needed)
            if obj.opt.potential_type == "tensor"
                % combine scalar 'a' and 3x3 matrix 'D' to 4x4 matrix
                validateattributes(D, {'numeric'}, {'nrows', 3, 'ncols', 3});
                V = pagefun(@inv, D);
                V(4,4,:,:,:,:) = 0; 
                V = V + padarray(shiftdim(a, -2), [3,3,0,0,0,0], 'pre');                
            elseif obj.opt.potential_type == "diagonal"
                % combine scalar 'a' and diagonal matrix 'D' to 4-element
                % diagonal matrix
                validateattributes(D, {'numeric'}, {'nrows', 3});
                V = 1./D;
                V(4,:,:,:,:) = 0;
                V = V + padarray(shiftdim(a, -1), [3,0,0,0,0], 'pre');
            elseif obj.opt.potential_type == "scalar" 
                % combine scalar 'a' and scalar 'D' to 4-element diagonal
                % matrix
                obj.opt.potential_type = "diagonal";
                V = repmat(shiftdim(1./D, -1), 3, 1, 1, 1, 1);
                V(4,:,:,:,:) = 0;
                V = V + padarray(shiftdim(a, -1), [3,0,0,0,0], 'pre');
            else
                error('Incorrect option for potential_type');
            end
            % perform scaling so that ‖V‖ < 1
            medium = makeMedium@GridSim(obj, V);
        end
        
        function propagator = makePropagator(obj)
            % Constructs the propagator (L'+1)^-1 = 
            % with L' = Tl(L + V0)Tr, and L the diffusion equation
            % differential operator.
            %
            % [               dx]
            % [     Q0        dy]
            % [               dz]
            % [dx dy dz (dt + a0*c)]
            V0 = obj.medium.V0; % scaled background potential
            Tl = obj.medium.Tl; % scaling matrices for the
            Tr = obj.medium.Tr; % L operator
            
            Lr = zero_array([4, 4, obj.grid.N], obj.opt);
            
            % insert dx, dy, dz, dt
            for d=1:4
                location = zeros(4,4);
                location(4, d) = 1.0i;
                location(d, 4) = 1.0i;
                dd = location .* shiftdim(obj.grid.coordinates_f(d), -2);
                Lr = Lr + dd;
            end
            
            % L' + 1 = Tl (L+V0) Tr + 1
            % simplified to: L' = Tl L Tr + Tl V0 Tr + 1
            Lr = pagemtimes(pagemtimes(Tl, Lr + V0), Tr);
                        
            % invert L to obtain dampened Green's operator
            % then make x,y,z,t dimensions hermitian to avoid
            % artefacts when N is even
            Lr = pageinv(Lr + eye(4));
            Lr = SimGrid.fix_edges_hermitian(Lr, 3:6); 
            
            % the propagator just performs a
            % page-wise matrix-vector multiplication
            propagator.apply = @(u, state) pagemtimes(Lr, u);
        end
        
        function Vmin = analyzeDimensions(obj, Vmax)
            % The scaled Green's function (L+1)^-1 decays exponentially in
            % space and time. This decay should be fast enough to ensure
            % convergence (this scaling is performed by makeMedium by
            % ensuring that the scaled potential V has ||V||<1).
            % The decay should also be fast enough to minimize wrap-around
            % artefacts. For this reason, we require the decay length/time
            % to be equal to a fraction of the size/duration of the
            % simulation in each dimension.
            % 
            % The decay coefficient for the diffusion equation is given by
            % mu_eff = sqrt(mu_a / D}        (assuming c=1)
            % Or, in term of elements of the un-scaled potential: 
            % mu_eff_j = sqrt(Vraw_t * Vraw_j)    
            % with j=x,y,z, or t. So, Vraw_t = mu_eff_t
            % and V_raw_j = mu_eff_j^2 / Vraw_t
            %
            % start by computing minimum required mu_eff in all dimensions

            active = obj.grid.N ~= 1;
            limiting_size = obj.grid.dimensions().';
            % requires same pixel size in all dimensions?
            limiting_size(obj.grid.boundaries.periodic) = max(limiting_size);
            mu_eff_min = 10 ./ limiting_size;
            
            % special case for steady state (t-axis inactive)
            if ~active(4)
                mu_eff_min(4) = max(mu_eff_min);
            end
            Vmin = mu_eff_min.^2 / mu_eff_min(4);
            
            % Now, check if the resolution is high enough to resolve the
            % smallest features
            Vmax = max(Vmin, Vmax);
            feature_size = 1./sqrt(Vmax(4) * Vmax(active)); %todo: correct for steady state?
            pixel_size = obj.grid.pixel_size(active);
            
            if any(feature_size/2 < pixel_size)
                res_limit = sprintf("%g ", feature_size/2);
                res_current = sprintf("%g ", pixel_size);
                warning("Resolution is too low to resolve the smallest features in the simulation. Minimum pixel size: [%s] Current pixel size: [%s]", res_limit, res_current);
            end
            if any(feature_size/8 > pixel_size)
                res_limit = sprintf("%g ", feature_size/2);
                res_current = sprintf("%g ", pixel_size);
                warning("Resolution seems to be on the high side. Minimum pixel size: [%s] Current pixel size: [%s]", res_limit, res_current);
            end
        end
    end
end
