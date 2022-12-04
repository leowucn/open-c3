(function() {
    'use strict';

    angular
        .module('openc3')
        .controller('MyackController', MyackController);

    function MyackController($http, ngTableParams, $uibModal, genericService) {
        var vm = this;
        vm.seftime = genericService.seftime

        vm.edit = function (ackuuid) {
            $http.post( '/api/agent/monitor/ack/myack/bycookie', { uuid: ackuuid} ).success(function(data){
                if (data.stat){
                    vm.reload();
                }else {
                    swal({ title: '操作失败', text: data.info, type:'error' });
                }
            });
        };

        vm.reload = function () {
            vm.loadover = false;
            $http.get('/api/agent/monitor/ack/myack/bycookie').success(function(data){
                if (data.stat){
                    vm.dataTable = new ngTableParams({count:25}, {counts:[],data:data.data});
                    vm.loadover = true;
                }else {
                    swal({ title:'获取列表失败', text: data.info, type:'error' });
                }
            });
        };
        vm.reload();
    }
})();
