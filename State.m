classdef State < dynamicprops
    %STATE Holds state variables (variables that change while running the
    %   algorithm.)
    %
    %   (c) 2019. Ivo Vellekoop    
    properties
        iteration;
        start_time;
        end_time;
        run_time;
        termination_condition_interval;
        termination_condition;
        callback_interval;
        callback;
        running;
        diffs;
        diff_its; % iteration numbers at which diffs were reported
        normb; % norm of the source (for normalizing 'diff')
    end
    
    methods
        function obj = State(sim, opt)
            obj.iteration = 1; %current iteration number
            obj.start_time = cputime; %only measure time actually used by MATLAB
            obj.running = true;
            obj.normb = [];
            obj.callback_interval = opt.callback.interval;
            obj.callback = opt.callback.handle(sim, opt.callback);
            obj.diffs = [];
            obj.termination_condition_interval = opt.termination_condition.interval; % how often to analyze the update du (for termination condition and/or visual feedback)
            obj.termination_condition = opt.termination_condition.handle(sim, opt.termination_condition);
        end
        function next(obj, u, r)
            if mod(obj.iteration-1, obj.termination_condition_interval) == 0
                if (obj.iteration == 1)
                    obj.normb = norm(r(:));
                end
                obj.diffs = [obj.diffs, norm(r(:))/obj.normb];
                obj.diff_its = [obj.diff_its, obj.iteration];
                obj.running = ~obj.termination_condition.call(obj);
            end
            if mod(obj.iteration-1, obj.callback_interval) == 0 && ~isempty(obj.callback)
                obj.callback.call(u, r, obj);
            end
            obj.iteration = obj.iteration + 1;
        end
        
        function finalize(obj)
            obj.end_time = cputime;
            obj.run_time = obj.end_time - obj.start_time;
        end
    end
    
end

