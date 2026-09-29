% v2.7 收敛探针：1600 步跟踪内部均温/排气流量/flowGain/三判据
s = CFDSolverFEM();
for blk = 1:16
    s.stepMultiple(100);
    c = s.computeConservationCheck();
    t = s.computeAirflowTemperatures();
    gross = sum(max(0, [c.flux.top.cfm c.flux.rear.cfm c.flux.front.cfm c.flux.bottom.cfm]));
    net = c.flux.top.cfm + c.flux.rear.cfm + c.flux.front.cfm + c.flux.bottom.cfm;
    fprintf('%5dsteps: Tint_alg=%.1f Tint_cfd=%.1f dT=%+.1f | gross=%.0fCFM net=%+.0f | gain=%.2f | A=%+.1f%% B=%+.1f%% | Tj_cpu=%.1f gpu=%.1f psu=%.1f\n', ...
        blk*100, t.internalAmbient, t.interiorMeanCFD, t.internalDiscrepancy, ...
        gross, net, s.flowGain, c.ledgerPct, c.residualPct, ...
        s.thermalNetworks.cpu.T_junction, s.thermalNetworks.gpu.T_junction, ...
        s.thermalNetworks.psu.T_junction);
end
